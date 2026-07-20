#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/CheckMyDisk.xcodeproj"
PROJECT_FILE="$PROJECT_PATH/project.pbxproj"
INFO_PLIST="$ROOT_DIR/Config/CheckMyDisk-Info.plist"
SCHEME="CheckMyDisk"
APP_BUNDLE_ID="com.checkmydisk.CheckMyDisk"
APP_NAME="CheckMyDisk.app"
BINARY_NAME="CheckMyDisk"
REPOSITORY="mikolatero/checkmydisk"
RELEASE_INFO_PATH="$ROOT_DIR/dist/release.env"
DERIVED_DATA_DIR="$ROOT_DIR/build/DerivedData"
XCODE_PACKAGE_RESOLVED="$PROJECT_PATH/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
SWIFT_PACKAGE_RESOLVED="$ROOT_DIR/Package.resolved"
REQUIRED_ARCHS=(arm64 x86_64)
export APP_BUNDLE_ID

usage() {
    echo "Uso: Scripts/publish_release.sh \"Descripción del cambio\"" >&2
}

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

set_app_build_settings() {
    local version="$1"
    local build="$2"

    NEW_MARKETING_VERSION="$version" NEW_CURRENT_PROJECT_VERSION="$build" PROJECT_FILE="$PROJECT_FILE" /usr/bin/perl -0 -e '
        my $path = $ENV{PROJECT_FILE};
        open my $fh, "<", $path or die "open $path: $!";
        local $/;
        my $content = <$fh>;
        close $fh;

        my $updated = 0;
        $content =~ s@(buildSettings = \{.*?\n\t\t\t\};)@
            my $block = $1;
            if ($block =~ /PRODUCT_BUNDLE_IDENTIFIER = \Q$ENV{APP_BUNDLE_ID}\E;/) {
                my $version_updates = ($block =~ s!MARKETING_VERSION = [^;]+;!MARKETING_VERSION = $ENV{NEW_MARKETING_VERSION};!g);
                my $build_updates = ($block =~ s!CURRENT_PROJECT_VERSION = [^;]+;!CURRENT_PROJECT_VERSION = $ENV{NEW_CURRENT_PROJECT_VERSION};!g);
                die "Missing version keys in app build settings\n" unless $version_updates == 1 && $build_updates == 1;
                $updated++;
            }
            $block;
        @gse;

        die "Expected two app build settings blocks, updated $updated\n" unless $updated == 2;

        open my $out, ">", $path or die "write $path: $!";
        print {$out} $content;
        close $out;
    '
}

scan_pending_changes() {
    local pending_paths
    local untracked_file
    local local_path_pattern="/""Users/[^/]+/"
    local private_key_pattern="-----BEGIN ""([A-Z0-9 ]+ )?PRIVATE KEY-----"
    local github_pat_pattern="github_""pat_[A-Za-z0-9_]{20,}"
    local github_token_pattern="gh""[pousr]_[A-Za-z0-9]{20,}"
    local sparkle_key_pattern="SPARKLE_""PRIVATE_KEY[[:space:]]*="
    local sensitive_content_pattern

    sensitive_content_pattern="$local_path_pattern|$private_key_pattern|$github_pat_pattern|$github_token_pattern|$sparkle_key_pattern"

    pending_paths="$(git status --porcelain=v1 --untracked-files=all | /usr/bin/cut -c4-)"
    if grep -Eq '(^|/)(build|dist|DerivedData)(/|$)|\.(ed25519|sparkle_private_key)$' <<< "$pending_paths"; then
        fail "Los cambios pendientes incluyen build, dist, DerivedData o una clave privada."
    fi

    if git ls-files | grep -Eq '(^|/)(build|dist|DerivedData)(/|$)|\.(ed25519|sparkle_private_key)$'; then
        fail "Git ya contiene un artefacto de build o una clave privada."
    fi

    if git diff --no-ext-diff --binary -- . | grep -E "^\+.*($sensitive_content_pattern)" >/dev/null; then
        fail "El diff contiene una ruta local, credencial o clave privada potencial."
    fi

    while IFS= read -r -d '' untracked_file; do
        [[ -f "$untracked_file" ]] || continue
        if grep -Iq . "$untracked_file" 2>/dev/null && grep -E "($sensitive_content_pattern)" "$untracked_file" >/dev/null 2>&1; then
            fail "El archivo nuevo '$untracked_file' contiene una ruta local, credencial o clave privada potencial."
        fi
    done < <(git ls-files --others --exclude-standard -z)
}

if [[ $# -lt 1 || -z "${1//[[:space:]]/}" ]]; then
    usage
    exit 1
fi

RELEASE_MESSAGE="$*"
cd "$ROOT_DIR"

require_command gh
require_command git
require_command jq
require_command plutil
require_command xcodebuild
require_command codesign
require_command lipo
require_command xcrun

[[ -f "$PROJECT_FILE" ]] || fail "No existe $PROJECT_FILE."
[[ "$(git branch --show-current)" == "main" ]] || fail "La publicación solo se permite desde la rama main."

gh auth status >/dev/null 2>&1 || fail "GitHub CLI no está autenticado. Ejecuta: gh auth login -h github.com"
gh auth setup-git >/dev/null 2>&1 || fail "No se pudieron configurar las credenciales Git. Ejecuta: gh auth setup-git"

CURRENT_MARKETING_VERSION="$(read_app_build_setting MARKETING_VERSION)"
CURRENT_PROJECT_VERSION="$(read_app_build_setting CURRENT_PROJECT_VERSION)"

if [[ "$CURRENT_MARKETING_VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    NEXT_MARKETING_VERSION="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((BASH_REMATCH[3] + 1))"
else
    fail "MARKETING_VERSION '$CURRENT_MARKETING_VERSION' no tiene formato X.Y.Z."
fi

[[ "$CURRENT_PROJECT_VERSION" =~ ^[0-9]+$ ]] || fail "CURRENT_PROJECT_VERSION '$CURRENT_PROJECT_VERSION' no es numérico."
NEXT_PROJECT_VERSION="$((CURRENT_PROJECT_VERSION + 1))"
TAG="v$NEXT_MARKETING_VERSION"

if git rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null; then
    fail "El tag local $TAG ya existe."
fi

set +e
git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1
REMOTE_TAG_STATUS=$?
set -e
case "$REMOTE_TAG_STATUS" in
    0) fail "El tag remoto $TAG ya existe." ;;
    2) ;;
    *) fail "No se pudo comprobar de forma segura si el tag remoto $TAG existe." ;;
esac

PROJECT_BACKUP="$(mktemp "${TMPDIR:-/tmp}/CheckMyDisk-project.XXXXXX")"
cp "$PROJECT_FILE" "$PROJECT_BACKUP"
PUBLISH_COMMITTED=0

restore_project_on_error() {
    local exit_code="$1"
    if [[ "$exit_code" -ne 0 && "$PUBLISH_COMMITTED" -eq 0 && -f "$PROJECT_BACKUP" ]]; then
        cp "$PROJECT_BACKUP" "$PROJECT_FILE"
        echo "Versiones restauradas porque la publicación falló antes del commit." >&2
    fi
    rm -f "$PROJECT_BACKUP"
}

trap 'restore_project_on_error $?' EXIT

echo "Preparando $TAG (build $NEXT_PROJECT_VERSION)"
set_app_build_settings "$NEXT_MARKETING_VERSION" "$NEXT_PROJECT_VERSION"

git diff --check
plutil -lint "$PROJECT_FILE" "$INFO_PLIST" >/dev/null

for package_resolved in "$XCODE_PACKAGE_RESOLVED" "$SWIFT_PACKAGE_RESOLVED"; do
    if [[ -f "$package_resolved" ]]; then
        jq empty "$package_resolved"
    fi
done

xcodebuild test \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -destination "platform=macOS" \
    -testLanguage en \
    -testRegion US \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- \
    DEVELOPMENT_TEAM= \
    ENABLE_HARDENED_RUNTIME=NO

"$ROOT_DIR/Scripts/prepare_update.sh"

[[ -s "$RELEASE_INFO_PATH" ]] || fail "No se generó $RELEASE_INFO_PATH."
# shellcheck disable=SC1090
source "$RELEASE_INFO_PATH"

[[ "${MARKETING_VERSION:-}" == "$NEXT_MARKETING_VERSION" ]] || fail "release.env contiene una versión inesperada: ${MARKETING_VERSION:-vacía}."
[[ "${CURRENT_PROJECT_VERSION:-}" == "$NEXT_PROJECT_VERSION" ]] || fail "release.env contiene un build inesperado: ${CURRENT_PROJECT_VERSION:-vacío}."
[[ -s "${ZIP_PATH:-}" ]] || fail "No existe el ZIP esperado: ${ZIP_PATH:-vacío}."
[[ -s "${APPCAST_PATH:-}" ]] || fail "No existe el appcast esperado: ${APPCAST_PATH:-vacío}."
[[ -d "${APP_PATH:-}" ]] || fail "No existe la aplicación esperada: ${APP_PATH:-vacía}."

EXPECTED_ZIP_NAME="CheckMyDisk-$NEXT_MARKETING_VERSION-$NEXT_PROJECT_VERSION.zip"
EXPECTED_DOWNLOAD_URL="https://github.com/$REPOSITORY/releases/download/$TAG/$EXPECTED_ZIP_NAME"
[[ "$ZIP_NAME" == "$EXPECTED_ZIP_NAME" ]] || fail "Nombre de ZIP inesperado: $ZIP_NAME."
[[ "$DOWNLOAD_URL" == "$EXPECTED_DOWNLOAD_URL" ]] || fail "URL de descarga inesperada: $DOWNLOAD_URL."

URL_COUNT="$(grep -Fc "url=\"$EXPECTED_DOWNLOAD_URL\"" "$APPCAST_PATH" || true)"
[[ "$URL_COUNT" -eq 1 ]] || fail "El appcast debe contener exactamente una enclosure con $EXPECTED_DOWNLOAD_URL."
grep -Fq 'sparkle:edSignature="' "$APPCAST_PATH" || fail "El appcast no contiene firma EdDSA."

[[ -d "$APP_PATH/Contents/Frameworks/Sparkle.framework" ]] || fail "La aplicación no contiene Sparkle.framework."

BUILT_INFO_PLIST="$APP_PATH/Contents/Info.plist"
plutil -lint "$BUILT_INFO_PLIST" >/dev/null
BUILT_MARKETING_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILT_INFO_PLIST")"
BUILT_PROJECT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$BUILT_INFO_PLIST")"
BUILT_FEED_URL="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$BUILT_INFO_PLIST")"
BUILT_PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$BUILT_INFO_PLIST")"
[[ "$BUILT_MARKETING_VERSION" == "$NEXT_MARKETING_VERSION" ]] || fail "CFBundleShortVersionString inesperado: $BUILT_MARKETING_VERSION."
[[ "$BUILT_PROJECT_VERSION" == "$NEXT_PROJECT_VERSION" ]] || fail "CFBundleVersion inesperado: $BUILT_PROJECT_VERSION."
[[ "$BUILT_FEED_URL" == "https://mikolatero.github.io/checkmydisk/appcast.xml" ]] || fail "SUFeedURL inesperada: $BUILT_FEED_URL."
[[ -n "$BUILT_PUBLIC_KEY" && "$BUILT_PUBLIC_KEY" != "SPARKLE_PUBLIC_KEY_PENDING" ]] || fail "SUPublicEDKey no está configurada."

codesign --verify --deep --strict "$APP_PATH"
CODESIGN_OUTPUT="$(codesign -dv "$APP_PATH" 2>&1)"
if [[ -n "${DEVELOPER_ID_APP_IDENTITY:-}" ]]; then
    if grep -Fq "Signature=adhoc" <<< "$CODESIGN_OUTPUT"; then
        fail "Se esperaba firma Developer ID pero la app está firmada ad-hoc. Revisa CODE_SIGN_IDENTITY[sdk=macosx*] en el pbxproj (puede ganar al override)."
    fi
    if [[ -n "${DEVELOPMENT_TEAM:-}" ]] && ! grep -Fq "TeamIdentifier=$DEVELOPMENT_TEAM" <<< "$CODESIGN_OUTPUT"; then
        fail "La firma no tiene el TeamIdentifier esperado ($DEVELOPMENT_TEAM)."
    fi
    xcrun stapler validate "$APP_PATH" || fail "El ticket de notarización no está grapado (xcrun stapler validate)."
    if ! spctl -a -vvv --type exec "$APP_PATH" 2>&1 | grep -Fq "source=Notarized Developer ID"; then
        fail "Gatekeeper no acepta la app como Developer ID notarizada."
    fi
else
    grep -Fq "Signature=adhoc" <<< "$CODESIGN_OUTPUT" || fail "La aplicación no está firmada ad-hoc."
    if grep -F "TeamIdentifier=" <<< "$CODESIGN_OUTPUT" | grep -Fqv "TeamIdentifier=not set"; then
        fail "La firma ad-hoc no debe tener TeamIdentifier."
    fi
fi

BINARY_ARCHS="$(lipo -archs "$APP_PATH/Contents/MacOS/$BINARY_NAME")"
for required_arch in "${REQUIRED_ARCHS[@]}"; do
    [[ " $BINARY_ARCHS " == *" $required_arch "* ]] || fail "El binario no contiene la arquitectura $required_arch."
done

scan_pending_changes
git add -A --dry-run >/dev/null
git add -A

if git diff --cached --name-only | grep -Eq '(^|/)(build|dist|DerivedData)(/|$)|\.(ed25519|sparkle_private_key)$'; then
    fail "El staging contiene un artefacto de build o una clave privada."
fi

git diff --cached --check
git diff --cached --quiet && fail "No hay cambios staged para publicar."

git commit -m "$RELEASE_MESSAGE" -m "Release $TAG"
PUBLISH_COMMITTED=1
git tag -a "$TAG" -m "Release $TAG"

git push origin main
git push origin "$TAG"

if gh release view "$TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
    gh release upload "$TAG" "$ZIP_PATH" --repo "$REPOSITORY" --clobber
    gh release edit "$TAG" --repo "$REPOSITORY" --title "$TAG" --notes "$RELEASE_MESSAGE"
else
    gh release create "$TAG" "$ZIP_PATH" --repo "$REPOSITORY" --title "$TAG" --notes "$RELEASE_MESSAGE"
fi

RELEASE_URL="$(gh release view "$TAG" --repo "$REPOSITORY" --json url --jq .url)"

echo "Versión: $NEXT_MARKETING_VERSION"
echo "Build: $NEXT_PROJECT_VERSION"
echo "Tag: $TAG"
echo "Asset: $ZIP_NAME"
echo "Descarga: $EXPECTED_DOWNLOAD_URL"
echo "Release: $RELEASE_URL"
