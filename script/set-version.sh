#!/bin/zsh
set -euo pipefail

if [[ $# -ne 2 ]]; then
    print -u2 "Usage: $0 <marketing-version> <build-number>"
    exit 64
fi

version="$1"
build="$2"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
    print -u2 "Marketing version must be X.Y.Z with an optional prerelease suffix"
    exit 64
fi

if [[ ! "$build" =~ ^[1-9][0-9]*$ ]]; then
    print -u2 "Build number must be a positive integer"
    exit 64
fi

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
pbxproj="$repo_root/Obelisk.xcodeproj/project.pbxproj"
app_bundle_id="com.eli.Obelisk"
expected_app_configurations=2

if [[ ! -f "$pbxproj" ]]; then
    print -u2 "Missing Xcode project: $pbxproj"
    exit 66
fi

ruby - "$pbxproj" "$version" "$build" "$app_bundle_id" "$expected_app_configurations" <<'RUBY'
path, version, build, bundle_id, expected = ARGV
expected = Integer(expected)
contents = File.read(path)
rewritten_marketing = 0
rewritten_build = 0

updated = contents.gsub(/(\t[A-F0-9]{24} \/\* (?:Debug|Release) \*\/ = \{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = \{.*?\n\t\t\t\};\n\t\t\tname = (?:Debug|Release);\n\t\t\};)/m) do |block|
  next block unless block.include?("PRODUCT_BUNDLE_IDENTIFIER = #{bundle_id};")

  unless block.sub!(/CURRENT_PROJECT_VERSION = [^;]+;/, "CURRENT_PROJECT_VERSION = #{build};")
    raise "App target configuration is missing CURRENT_PROJECT_VERSION"
  end
  rewritten_build += 1

  unless block.sub!(/MARKETING_VERSION = [^;]+;/, "MARKETING_VERSION = #{version};")
    raise "App target configuration is missing MARKETING_VERSION"
  end
  rewritten_marketing += 1

  block
end

if rewritten_marketing != expected || rewritten_build != expected
  warn "Expected #{expected} app-target version rewrites, updated marketing=#{rewritten_marketing} build=#{rewritten_build}"
  exit 70
end

File.write(path, updated)
RUBY

print "Obelisk version set to ${version} (${build})"
