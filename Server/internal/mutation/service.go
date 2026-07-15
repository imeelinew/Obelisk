package mutation

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type LogicalTimestamp struct {
	Milliseconds int64     `json:"milliseconds"`
	Counter      uint32    `json:"counter"`
	DeviceID     uuid.UUID `json:"deviceID"`
}

func (timestamp LogicalTimestamp) After(other LogicalTimestamp) bool {
	if timestamp.Milliseconds != other.Milliseconds {
		return timestamp.Milliseconds > other.Milliseconds
	}
	if timestamp.Counter != other.Counter {
		return timestamp.Counter > other.Counter
	}
	return timestamp.DeviceID.String() > other.DeviceID.String()
}

type Mutation struct {
	MutationID uuid.UUID                  `json:"mutationId"`
	Table      string                     `json:"table"`
	RowID      uuid.UUID                  `json:"rowId"`
	Operation  string                     `json:"operation"`
	Values     map[string]json.RawMessage `json:"values"`
}

type Request struct {
	Mutations []Mutation `json:"mutations"`
}

type Service struct {
	pool *pgxpool.Pool
}

type fieldDecoder func(json.RawMessage) (any, error)

var collectionFields = map[string]fieldDecoder{
	"name":         requiredString,
	"position_key": requiredString,
	"show_in_menu": requiredBoolean,
	"deleted_at":   optionalTime,
}

var bookmarkFields = map[string]fieldDecoder{
	"collection_id":   optionalUUID,
	"title":           requiredString,
	"url":             requiredString,
	"title_optimized": requiredBoolean,
	"is_hidden":       requiredBoolean,
	"archived_at":     optionalTime,
	"is_pinned":       requiredBoolean,
	"original_title":  optionalString,
	"position_key":    requiredString,
	"deleted_at":      optionalTime,
}

var browserHistorySettingsFields = map[string]fieldDecoder{
	"enabled_sources": requiredBrowserHistorySources,
}

func NewService(pool *pgxpool.Pool) *Service {
	return &Service{pool: pool}
}

func (service *Service) Apply(
	ctx context.Context,
	ownerID uuid.UUID,
	deviceID uuid.UUID,
	request Request,
) error {
	if len(request.Mutations) == 0 || len(request.Mutations) > 500 {
		return errors.New("a mutation batch must contain 1 to 500 entries")
	}

	tx, err := service.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin mutation transaction: %w", err)
	}
	defer tx.Rollback(ctx)

	for _, item := range request.Mutations {
		applied, err := recordMutation(ctx, tx, ownerID, deviceID, item.MutationID)
		if err != nil {
			return err
		}
		if !applied {
			continue
		}

		switch item.Table {
		case "collections":
			err = applyVersionedRow(ctx, tx, ownerID, deviceID, item, "collections", collectionFields)
		case "bookmarks":
			err = applyVersionedRow(ctx, tx, ownerID, deviceID, item, "bookmarks", bookmarkFields)
			if err == nil {
				err = enforceBookmarkInvariants(ctx, tx, ownerID, item.RowID)
			}
		case "usage_events":
			err = applyUsageEvent(ctx, tx, ownerID, deviceID, item)
		case "browser_history_events":
			err = applyBrowserHistoryEvent(ctx, tx, ownerID, deviceID, item)
		case "browser_history_settings":
			err = applyVersionedRow(
				ctx,
				tx,
				ownerID,
				deviceID,
				item,
				"browser_history_settings",
				browserHistorySettingsFields,
			)
		default:
			err = fmt.Errorf("unsupported mutation table %q", item.Table)
		}
		if err != nil {
			return err
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit mutations: %w", err)
	}
	return nil
}

func recordMutation(
	ctx context.Context,
	tx pgx.Tx,
	ownerID uuid.UUID,
	deviceID uuid.UUID,
	mutationID uuid.UUID,
) (bool, error) {
	if mutationID == uuid.Nil {
		return false, errors.New("mutationId is required")
	}
	var inserted uuid.UUID
	err := tx.QueryRow(ctx, `
		INSERT INTO applied_mutations(owner_id, device_id, mutation_id)
		VALUES ($1, $2, $3)
		ON CONFLICT DO NOTHING
		RETURNING mutation_id
	`, ownerID, deviceID, mutationID).Scan(&inserted)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("record mutation: %w", err)
	}
	return true, nil
}

func applyVersionedRow(
	ctx context.Context,
	tx pgx.Tx,
	ownerID uuid.UUID,
	deviceID uuid.UUID,
	mutation Mutation,
	table string,
	fields map[string]fieldDecoder,
) error {
	if mutation.Operation != "PUT" && mutation.Operation != "PATCH" {
		return fmt.Errorf("%s only accepts PUT and PATCH", table)
	}
	incomingVersions, err := versionsFromValues(mutation.Values)
	if err != nil {
		return err
	}

	var currentJSON []byte
	query := fmt.Sprintf("SELECT field_versions FROM %s WHERE id = $1 AND owner_id = $2 FOR UPDATE", table)
	err = tx.QueryRow(ctx, query, mutation.RowID, ownerID).Scan(&currentJSON)
	if errors.Is(err, pgx.ErrNoRows) {
		if mutation.Operation != "PUT" {
			return fmt.Errorf("cannot patch missing %s row %s", table, mutation.RowID)
		}
		return insertVersionedRow(ctx, tx, ownerID, deviceID, mutation, table, fields, incomingVersions)
	}
	if err != nil {
		return fmt.Errorf("select %s row: %w", table, err)
	}

	currentVersions := map[string]LogicalTimestamp{}
	if err := json.Unmarshal(currentJSON, &currentVersions); err != nil {
		return fmt.Errorf("decode stored field_versions: %w", err)
	}
	columns, arguments, mergedVersions, err := mergeFields(
		mutation.Values,
		fields,
		incomingVersions,
		currentVersions,
		deviceID,
	)
	if err != nil {
		return err
	}
	if len(columns) == 0 {
		return nil
	}

	sets := make([]string, 0, len(columns)+2)
	for index, column := range columns {
		sets = append(sets, fmt.Sprintf("%s = $%d", column, index+1))
	}
	versionsJSON, err := json.Marshal(mergedVersions)
	if err != nil {
		return err
	}
	sets = append(sets, fmt.Sprintf("field_versions = $%d::jsonb", len(arguments)+1))
	arguments = append(arguments, string(versionsJSON))
	sets = append(sets, "updated_at = now()")
	arguments = append(arguments, mutation.RowID, ownerID)
	update := fmt.Sprintf(
		"UPDATE %s SET %s WHERE id = $%d AND owner_id = $%d",
		table,
		strings.Join(sets, ", "),
		len(arguments)-1,
		len(arguments),
	)
	if _, err := tx.Exec(ctx, update, arguments...); err != nil {
		return fmt.Errorf("update %s row: %w", table, err)
	}
	return nil
}

func insertVersionedRow(
	ctx context.Context,
	tx pgx.Tx,
	ownerID uuid.UUID,
	deviceID uuid.UUID,
	mutation Mutation,
	table string,
	fields map[string]fieldDecoder,
	versions map[string]LogicalTimestamp,
) error {
	columns := make([]string, 0, len(fields))
	arguments := make([]any, 0, len(fields)+5)
	for field, decode := range fields {
		raw, ok := mutation.Values[field]
		if !ok {
			raw = json.RawMessage("null")
		}
		timestamp, ok := versions[field]
		if !ok || timestamp.DeviceID != deviceID {
			return fmt.Errorf("invalid field version for %s", field)
		}
		value, err := decode(raw)
		if err != nil {
			return fmt.Errorf("decode %s: %w", field, err)
		}
		columns = append(columns, field)
		arguments = append(arguments, value)
	}
	versionsJSON, err := json.Marshal(versions)
	if err != nil {
		return err
	}
	createdAt := time.Now().UTC()
	if raw, ok := mutation.Values["created_at"]; ok {
		createdAt, err = requiredTime(raw)
		if err != nil {
			return fmt.Errorf("decode created_at: %w", err)
		}
	}

	placeholders := make([]string, 0, len(arguments)+5)
	for index := range arguments {
		placeholders = append(placeholders, "$"+strconv.Itoa(index+1))
	}
	base := len(arguments)
	columns = append(columns, "id", "owner_id", "field_versions", "created_at", "updated_at")
	arguments = append(arguments, mutation.RowID, ownerID, string(versionsJSON), createdAt, time.Now().UTC())
	placeholders = append(
		placeholders,
		"$"+strconv.Itoa(base+1),
		"$"+strconv.Itoa(base+2),
		"$"+strconv.Itoa(base+3)+"::jsonb",
		"$"+strconv.Itoa(base+4),
		"$"+strconv.Itoa(base+5),
	)
	insert := fmt.Sprintf(
		"INSERT INTO %s (%s) VALUES (%s)",
		table,
		strings.Join(columns, ", "),
		strings.Join(placeholders, ", "),
	)
	if _, err := tx.Exec(ctx, insert, arguments...); err != nil {
		return fmt.Errorf("insert %s row: %w", table, err)
	}
	return nil
}

func mergeFields(
	values map[string]json.RawMessage,
	fields map[string]fieldDecoder,
	incomingVersions map[string]LogicalTimestamp,
	currentVersions map[string]LogicalTimestamp,
	deviceID uuid.UUID,
) ([]string, []any, map[string]LogicalTimestamp, error) {
	columns := make([]string, 0, len(values))
	arguments := make([]any, 0, len(values))
	merged := make(map[string]LogicalTimestamp, len(currentVersions))
	for field, version := range currentVersions {
		merged[field] = version
	}

	for field, decode := range fields {
		raw, included := values[field]
		if !included {
			continue
		}
		incoming, ok := incomingVersions[field]
		if !ok {
			return nil, nil, nil, fmt.Errorf("invalid field version for %s", field)
		}
		if current, exists := currentVersions[field]; exists && !incoming.After(current) {
			continue
		}
		if incoming.DeviceID != deviceID {
			return nil, nil, nil, fmt.Errorf("invalid field version for %s", field)
		}
		value, err := decode(raw)
		if err != nil {
			return nil, nil, nil, fmt.Errorf("decode %s: %w", field, err)
		}
		columns = append(columns, field)
		arguments = append(arguments, value)
		merged[field] = incoming
	}
	return columns, arguments, merged, nil
}

func versionsFromValues(values map[string]json.RawMessage) (map[string]LogicalTimestamp, error) {
	raw, ok := values["field_versions"]
	if !ok {
		return nil, errors.New("field_versions is required")
	}
	var encoded string
	if err := json.Unmarshal(raw, &encoded); err != nil {
		return nil, errors.New("field_versions must be a JSON string")
	}
	versions := map[string]LogicalTimestamp{}
	if err := json.Unmarshal([]byte(encoded), &versions); err != nil {
		return nil, fmt.Errorf("decode field_versions: %w", err)
	}
	return versions, nil
}

func enforceBookmarkInvariants(ctx context.Context, tx pgx.Tx, ownerID, rowID uuid.UUID) error {
	var hidden bool
	var pinned bool
	var archivedAt *time.Time
	var deletedAt *time.Time
	var rawVersions []byte
	err := tx.QueryRow(ctx, `
		SELECT is_hidden, is_pinned, archived_at, deleted_at, field_versions
		FROM bookmarks
		WHERE id = $1 AND owner_id = $2
		FOR UPDATE
	`, rowID, ownerID).Scan(&hidden, &pinned, &archivedAt, &deletedAt, &rawVersions)
	if err != nil {
		return err
	}
	if !pinned || (!hidden && archivedAt == nil && deletedAt == nil) {
		return nil
	}
	versions := map[string]LogicalTimestamp{}
	if err := json.Unmarshal(rawVersions, &versions); err != nil {
		return err
	}
	maximum := versions["is_pinned"]
	for _, field := range []string{"is_hidden", "archived_at", "deleted_at"} {
		if candidate := versions[field]; candidate.After(maximum) {
			maximum = candidate
		}
	}
	versions["is_pinned"] = maximum
	encoded, err := json.Marshal(versions)
	if err != nil {
		return err
	}
	_, err = tx.Exec(ctx, `
		UPDATE bookmarks
		SET is_pinned = false, field_versions = $3::jsonb, updated_at = now()
		WHERE id = $1 AND owner_id = $2
	`, rowID, ownerID, string(encoded))
	return err
}

func applyUsageEvent(
	ctx context.Context,
	tx pgx.Tx,
	ownerID uuid.UUID,
	deviceID uuid.UUID,
	mutation Mutation,
) error {
	if mutation.Operation != "PUT" {
		return errors.New("usage_events only accepts PUT")
	}
	bookmarkID, err := requiredUUID(mutation.Values["bookmark_id"])
	if err != nil {
		return fmt.Errorf("decode bookmark_id: %w", err)
	}
	occurredAt, err := requiredTime(mutation.Values["occurred_at"])
	if err != nil {
		return fmt.Errorf("decode occurred_at: %w", err)
	}
	_, err = tx.Exec(ctx, `
		INSERT INTO usage_events(id, owner_id, bookmark_id, device_id, occurred_at)
		VALUES ($1, $2, $3, $4, $5)
		ON CONFLICT (id) DO NOTHING
	`, mutation.RowID, ownerID, bookmarkID, deviceID, occurredAt)
	if err != nil {
		return fmt.Errorf("insert usage event: %w", err)
	}
	return nil
}

func applyBrowserHistoryEvent(
	ctx context.Context,
	tx pgx.Tx,
	ownerID uuid.UUID,
	deviceID uuid.UUID,
	mutation Mutation,
) error {
	if mutation.Operation == "DELETE" {
		_, err := tx.Exec(ctx, `
			DELETE FROM browser_history_events
			WHERE id = $1 AND owner_id = $2
		`, mutation.RowID, ownerID)
		if err != nil {
			return fmt.Errorf("delete browser history event: %w", err)
		}
		return nil
	}
	if mutation.Operation != "PUT" {
		return errors.New("browser_history_events only accepts PUT and DELETE")
	}
	browserValue, err := requiredString(mutation.Values["browser"])
	if err != nil {
		return fmt.Errorf("decode browser: %w", err)
	}
	browser := browserValue.(string)
	if !isSupportedBrowserHistoryBrowser(browser) {
		return errors.New("browser is invalid")
	}
	profileName, err := requiredString(mutation.Values["profile_name"])
	if err != nil {
		return fmt.Errorf("decode profile_name: %w", err)
	}
	title, err := requiredString(mutation.Values["title"])
	if err != nil {
		return fmt.Errorf("decode title: %w", err)
	}
	urlValue, err := requiredString(mutation.Values["url"])
	if err != nil {
		return fmt.Errorf("decode url: %w", err)
	}
	rawURL := urlValue.(string)
	parsedURL, err := url.ParseRequestURI(rawURL)
	if err != nil || (strings.ToLower(parsedURL.Scheme) != "https" && strings.ToLower(parsedURL.Scheme) != "http") {
		return errors.New("url must use http or https")
	}
	visitedAt, err := requiredTime(mutation.Values["visited_at"])
	if err != nil {
		return fmt.Errorf("decode visited_at: %w", err)
	}
	_, err = tx.Exec(ctx, `
		INSERT INTO browser_history_events(
			id, owner_id, source_device_id, browser, profile_name,
			title, url, visited_at
		)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
		ON CONFLICT (id) DO NOTHING
	`, mutation.RowID, ownerID, deviceID, browser, profileName, title, rawURL, visitedAt)
	if err != nil {
		return fmt.Errorf("insert browser history event: %w", err)
	}
	return nil
}

func isSupportedBrowserHistoryBrowser(browser string) bool {
	switch browser {
	case "dia", "chrome", "safari":
		return true
	default:
		return false
	}
}

func requiredBrowserHistorySources(raw json.RawMessage) (any, error) {
	var value *string
	if len(raw) == 0 || json.Unmarshal(raw, &value) != nil || value == nil {
		return nil, errors.New("enabled_sources must be a string")
	}
	if *value == "" {
		return *value, nil
	}
	seen := map[string]bool{}
	for _, browser := range strings.Split(*value, ",") {
		if !isSupportedBrowserHistoryBrowser(browser) || seen[browser] {
			return nil, errors.New("enabled_sources is invalid")
		}
		seen[browser] = true
	}
	canonical := make([]string, 0, len(seen))
	for _, browser := range []string{"dia", "chrome", "safari"} {
		if seen[browser] {
			canonical = append(canonical, browser)
		}
	}
	if strings.Join(canonical, ",") != *value {
		return nil, errors.New("enabled_sources is invalid")
	}
	return *value, nil
}

func requiredString(raw json.RawMessage) (any, error) {
	var value string
	if len(raw) == 0 || json.Unmarshal(raw, &value) != nil || value == "" {
		return nil, errors.New("required string is missing")
	}
	return value, nil
}

func optionalString(raw json.RawMessage) (any, error) {
	if string(raw) == "null" {
		return nil, nil
	}
	var value string
	if err := json.Unmarshal(raw, &value); err != nil {
		return nil, err
	}
	return value, nil
}

func requiredBoolean(raw json.RawMessage) (any, error) {
	var value *bool
	if len(raw) != 0 && json.Unmarshal(raw, &value) == nil && value != nil {
		return *value, nil
	}
	var integer *int
	if json.Unmarshal(raw, &integer) == nil && integer != nil && (*integer == 0 || *integer == 1) {
		return *integer == 1, nil
	}
	return nil, errors.New("required boolean is missing")
}

func requiredUUID(raw json.RawMessage) (uuid.UUID, error) {
	value, err := requiredString(raw)
	if err != nil {
		return uuid.Nil, err
	}
	return uuid.Parse(value.(string))
}

func optionalUUID(raw json.RawMessage) (any, error) {
	if string(raw) == "null" {
		return nil, nil
	}
	return requiredUUID(raw)
}

func requiredTime(raw json.RawMessage) (time.Time, error) {
	value, err := requiredString(raw)
	if err != nil {
		return time.Time{}, err
	}
	return time.Parse(time.RFC3339Nano, value.(string))
}

func optionalTime(raw json.RawMessage) (any, error) {
	if string(raw) == "null" {
		return nil, nil
	}
	return requiredTime(raw)
}
