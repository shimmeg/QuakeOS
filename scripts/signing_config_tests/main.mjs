import assert from "node:assert/strict";
import fs from "node:fs";

const project = fs.readFileSync("Quake4Mac.xcodeproj/project.pbxproj", "utf8");
const gitignore = fs.readFileSync(".gitignore", "utf8");

assert.ok(fs.existsSync("Config/Signing.xcconfig"), "committed signing base config exists");
assert.ok(fs.existsSync("Config/Signing.local.example.xcconfig"), "committed local signing example exists");
assert.match(gitignore, /^\/Config\/Signing\.local\.xcconfig$/m, "local signing override is ignored");

const signingConfig = fs.readFileSync("Config/Signing.xcconfig", "utf8");
const localExample = fs.readFileSync("Config/Signing.local.example.xcconfig", "utf8");
assert.match(signingConfig, /CODE_SIGN_STYLE\s*=\s*Automatic/, "base signing config uses automatic signing");
assert.match(signingConfig, /CODE_SIGN_IDENTITY\s*=\s*Apple Development/, "base signing config uses Apple Development identity");
assert.match(signingConfig, /^DEVELOPMENT_TEAM\s*=\s*$/m, "base signing config leaves team empty");
assert.match(signingConfig, /^PROVISIONING_PROFILE_SPECIFIER\s*=\s*$/m, "base signing config leaves provisioning profile empty");
assert.match(signingConfig, /#include\?\s+"Signing\.local\.xcconfig"/, "base signing config optionally includes local override");
assert.match(localExample, /^DEVELOPMENT_TEAM\s*=\s*YOUR_TEAM_ID$/m, "local signing example uses a placeholder team");
assert.match(localExample, /^CODE_SIGN_STYLE\s*=\s*Manual$/m, "local signing example uses the CLI-tested manual signing mode");
assert.match(localExample, /^CODE_SIGN_IDENTITY\s*=\s*Apple Development$/m, "local signing example uses Apple Development identity");

assert.match(project, /\/\* Signing\.xcconfig \*\//, "Xcode project references Signing.xcconfig");
assert.match(project, /baseConfigurationReference = [A-F0-9]+ \/\* Signing\.xcconfig \*\//, "target configurations use Signing.xcconfig as base config");
assert.doesNotMatch(project, /DEVELOPMENT_TEAM\s*=\s*[A-Z0-9]+;/, "project file does not commit a personal development team");
assert.doesNotMatch(project, /CODE_SIGN_IDENTITY\s*=\s*"-";/, "project file no longer disables signing via identity '-'");
assert.doesNotMatch(project, /CODE_SIGN_STYLE\s*=\s*Manual;/, "project file no longer hardcodes manual signing");
assert.doesNotMatch(project, /PROVISIONING_PROFILE_SPECIFIER\s*=\s*"";/, "project file does not override local provisioning profile settings");

console.log("PASS signing config");
