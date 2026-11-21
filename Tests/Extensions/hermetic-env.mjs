// Imported first by every Tests/Extensions/*.test.mjs. The suite runs inside agent threads whose environment
// describes that thread (PI_MODEL, SHEPHERD_EXT_VISION, SHEPHERD_CLI_SOCKET, ...). Left in place, those change what the
// extensions do (a text-only model's thread sets SHEPHERD_EXT_VISION, which makes board_render attach a picture), so
// the result would depend on who ran it. Drop them all; a test that needs one sets it itself. PI_PACKAGE_DIR is
// the harness's own input.
for (const key of Object.keys(process.env)) if (/^(PI|SHEPHERD)_/.test(key) && key !== "PI_PACKAGE_DIR") delete process.env[key];
