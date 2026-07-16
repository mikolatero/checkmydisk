#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/CheckMyDisk.xcodeproj"
PROJECT_FILE="$PROJECT_PATH/project.pbxproj"
SCHEME="CheckMyDisk"
APP_BUNDLE_ID="com.checkmydisk.CheckMyDisk"
APP_NAME="CheckMyDisk.app"
RELEASE_NAME="CheckMyDisk"
BINARY_NAME="CheckMyDisk"
REPOSITORY="mikolatero/checkmydisk"
SPARKLE_KEY_ACCOUNT="com.checkmydisk.CheckMyDisk"
DERIVED_DATA_DIR="$ROOT_DIR/build/DerivedData"
APPCAST_WORK_DIR="$ROOT_DIR/build/appcast"
DIST_DIR="$ROOT_DIR/dist"
DOCS_DIR="$ROOT_DIR/docs"
RELEASE_INFO_PATH="$DIST_DIR/release.env"
UNIVERSAL_ARCHS="arm64 x86_64"
export APP_BUNDLE_ID

fail() {
    echo "Error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "No se encontró '$1' en PATH."
}

read_app_build_setting() {
    local key="$1"
    local values
    local value_count
    local unique_count

    values="$(SETTING_KEY="$key" /usr/bin/perl -0ne '
        my $key = $ENV{SETTING_KEY};
        while (/buildSettings = \{.*?\n\t\t\t\};/sg) {
            my $block = $&;
            next unless $block =~ /PRODUCT_BUNDLE_IDENTIFIER = \Q$ENV{APP_BUNDLE_ID}\E;/;
            if ($block =~ /\Q$key\E = ([^;]+);/) {
                my $value = $1;
                $value =~ s/^"//;
                $value =~ s/"$//;
                print "$value\n";
            }
        }
    ' "$PROJECT_FILE")"

    value_count="$(printf '%s\n' "$values" | /usr/bin/awk 'NF { count++ } END { print count + 0 }')"
    [[ "$value_count" -eq 2 ]] || fail "Se esperaban dos valores de $key para el target $APP_BUNDLE_ID y se encontraron $value_count."

    unique_count="$(printf '%s\n' "$values" | /usr/bin/awk 'NF' | /usr/bin/sort -u | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
    [[ "$unique_count" -eq 1 ]] || fail "$key no coincide entre Debug y Release del target $APP_BUNDLE_ID."

    printf '%s\n' "$values" | /usr/bin/awk 'NF { print; exit }'
}

require_command xcodebuild
require_command ditto
require_command find
require_command grep
require_command cp

[[ -f "$PROJECT_FILE" ]] || fail "No existe $PROJECT_FILE."

MARKETING_VERSION="$(read_app_build_setting MARKETING_VERSION)"
CURRENT_PROJECT_VERSION="$(read_app_build_setting CURRENT_PROJECT_VERSION)"

[[ "$MARKETING_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "MARKETING_VERSION '$MARKETING_VERSION' no tiene formato X.Y.Z."
[[ "$CURRENT_PROJECT_VERSION" =~ ^[0-9]+$ ]] || fail "CURRENT_PROJECT_VERSION '$CURRENT_PROJECT_VERSION' no es numérico."

ZIP_NAME="$RELEASE_NAME-$MARKETING_VERSION-$CURRENT_PROJECT_VERSION.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"
DOWNLOAD_URL_PREFIX="https://github.com/$REPOSITORY/releases/download/v$MARKETING_VERSION/"
DOWNLOAD_URL="$DOWNLOAD_URL_PREFIX$ZIP_NAME"

mkdir -p "$DERIVED_DATA_DIR" "$DIST_DIR" "$DOCS_DIR"
rm -rf "$APPCAST_WORK_DIR"
mkdir -p "$APPCAST_WORK_DIR"

xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- \
    DEVELOPMENT_TEAM= \
    ENABLE_HARDENED_RUNTIME=NO \
    ONLY_ACTIVE_ARCH=NO \
    "ARCHS=$UNIVERSAL_ARCHS" \
    build

APP_PATH="$DERIVED_DATA_DIR/Build/Products/Release/$APP_NAME"
[[ -d "$APP_PATH" ]] || fail "No se encontró la aplicación compilada en $APP_PATH."
[[ -x "$APP_PATH/Contents/MacOS/$BINARY_NAME" ]] || fail "No existe el binario principal $APP_PATH/Contents/MacOS/$BINARY_NAME."

rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
[[ -s "$ZIP_PATH" ]] || fail "No se creó correctamente el ZIP $ZIP_PATH."

if [[ -s "$DOCS_DIR/appcast.xml" ]]; then
    cp "$DOCS_DIR/appcast.xml" "$APPCAST_WORK_DIR/appcast.xml"
fi
cp "$ZIP_PATH" "$APPCAST_WORK_DIR/$ZIP_NAME"
[[ -s "$APPCAST_WORK_DIR/$ZIP_NAME" ]] || fail "No se pudo copiar el ZIP al directorio temporal del appcast."

GENERATE_APPCAST=""
if [[ -n "${SPARKLE_TOOLS_DIR:-}" && -x "$SPARKLE_TOOLS_DIR/generate_appcast" ]]; then
    GENERATE_APPCAST="$SPARKLE_TOOLS_DIR/generate_appcast"
else
    GENERATE_APPCAST="$(find "$DERIVED_DATA_DIR/SourcePackages" -type f -path '*/Sparkle/bin/generate_appcast' -perm -111 2>/dev/null | /usr/bin/head -n 1 || true)"
fi

[[ -n "$GENERATE_APPCAST" && -x "$GENERATE_APPCAST" ]] || fail "No se encontró generate_appcast. Ejecuta xcodebuild -resolvePackageDependencies o define SPARKLE_TOOLS_DIR."
SIGN_UPDATE="$(dirname "$GENERATE_APPCAST")/sign_update"
[[ -x "$SIGN_UPDATE" ]] || fail "No se encontró sign_update junto a $GENERATE_APPCAST."

GENERATE_HELP="$("$GENERATE_APPCAST" --help 2>&1 || true)"
GENERATE_ARGS=()

if grep -q -- "--account" <<< "$GENERATE_HELP"; then
    GENERATE_ARGS+=(--account "$SPARKLE_KEY_ACCOUNT")
else
    fail "Esta versión de generate_appcast no soporta --account; no se puede garantizar la clave exclusiva de CheckMyDisk."
fi

if grep -q -- "--download-url-prefix" <<< "$GENERATE_HELP"; then
    GENERATE_ARGS+=(--download-url-prefix "$DOWNLOAD_URL_PREFIX")
fi

if grep -q -- "--disable-delta-updates" <<< "$GENERATE_HELP"; then
    GENERATE_ARGS+=(--disable-delta-updates)
fi

"$GENERATE_APPCAST" "${GENERATE_ARGS[@]}" "$APPCAST_WORK_DIR"

[[ -s "$APPCAST_WORK_DIR/appcast.xml" ]] || fail "generate_appcast no generó $APPCAST_WORK_DIR/appcast.xml."
cp "$APPCAST_WORK_DIR/appcast.xml" "$DOCS_DIR/appcast.xml"
[[ -s "$DOCS_DIR/appcast.xml" ]] || fail "No se pudo copiar el appcast a $DOCS_DIR/appcast.xml."

URL_COUNT="$(grep -Fc "url=\"$DOWNLOAD_URL\"" "$DOCS_DIR/appcast.xml" || true)"
[[ "$URL_COUNT" -eq 1 ]] || fail "El appcast debe contener exactamente una enclosure con $DOWNLOAD_URL; se encontraron $URL_COUNT."
grep -Fq 'sparkle:edSignature="' "$DOCS_DIR/appcast.xml" || fail "El appcast no contiene una firma EdDSA."
ED_SIGNATURE="$(/usr/bin/perl -ne 'if (/sparkle:edSignature="([^"]+)"/) { print $1; exit }' "$DOCS_DIR/appcast.xml")"
[[ -n "$ED_SIGNATURE" ]] || fail "No se pudo extraer la firma EdDSA del appcast."
"$SIGN_UPDATE" --account "$SPARKLE_KEY_ACCOUNT" --verify "$ZIP_PATH" "$ED_SIGNATURE" || fail "La firma EdDSA del ZIP no es válida para la cuenta $SPARKLE_KEY_ACCOUNT."

{
    printf 'MARKETING_VERSION=%q\n' "$MARKETING_VERSION"
    printf 'CURRENT_PROJECT_VERSION=%q\n' "$CURRENT_PROJECT_VERSION"
    printf 'ZIP_NAME=%q\n' "$ZIP_NAME"
    printf 'ZIP_PATH=%q\n' "$ZIP_PATH"
    printf 'DOWNLOAD_URL=%q\n' "$DOWNLOAD_URL"
    printf 'APPCAST_PATH=%q\n' "$DOCS_DIR/appcast.xml"
    printf 'APP_PATH=%q\n' "$APP_PATH"
} > "$RELEASE_INFO_PATH"

[[ -s "$RELEASE_INFO_PATH" ]] || fail "No se pudo crear $RELEASE_INFO_PATH."

echo "ZIP listo: $ZIP_PATH"
echo "Appcast listo: $DOCS_DIR/appcast.xml"
echo "Release info: $RELEASE_INFO_PATH"
echo "URL de descarga prevista: $DOWNLOAD_URL"
