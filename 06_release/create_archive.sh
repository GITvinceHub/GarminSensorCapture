#!/usr/bin/env bash
# =============================================================================
# create_archive.sh — Package GarminSensorCapture v1.0.0 for distribution
#
# Usage:
#   bash 06_release/create_archive.sh [--version X.Y.Z]
#
# Creates: GarminSensorCapture_vX.Y.Z_YYYYMMDD.zip in 06_release/
# =============================================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────

VERSION="1.0.0"
DATE=$(date +%Y%m%d)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ARCHIVE_NAME="GarminSensorCapture_v${VERSION}_${DATE}.zip"
ARCHIVE_PATH="${SCRIPT_DIR}/${ARCHIVE_NAME}"

# ── Parse arguments ───────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case $1 in
        --version)
            VERSION="$2"
            ARCHIVE_NAME="GarminSensorCapture_v${VERSION}_${DATE}.zip"
            ARCHIVE_PATH="${SCRIPT_DIR}/${ARCHIVE_NAME}"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [--version X.Y.Z]"
            echo "Creates a distributable ZIP archive of GarminSensorCapture."
            exit 0
            ;;
        *)
            echo "Unknown argument: $1"
            exit 1
            ;;
    esac
done

echo "============================================================"
echo "  GarminSensorCapture — Create Release Archive"
echo "  Version : ${VERSION}"
echo "  Date    : ${DATE}"
echo "  Output  : ${ARCHIVE_PATH}"
echo "============================================================"

# ── Pre-flight checks ─────────────────────────────────────────────────────────

if ! command -v zip &>/dev/null; then
    echo "ERROR: 'zip' not found. Install it with:"
    echo "  Ubuntu/Debian: sudo apt-get install zip"
    echo "  macOS:         brew install zip"
    echo "  Windows (Git Bash): zip is included with Git for Windows"
    exit 1
fi

if [[ ! -d "$PROJECT_ROOT" ]]; then
    echo "ERROR: Project root not found: $PROJECT_ROOT"
    exit 1
fi

# ── Files and directories to include ──────────────────────────────────────────

INCLUDES=(
    "01_watch_app_connectiq/manifest.xml"
    "01_watch_app_connectiq/source"
    "01_watch_app_connectiq/resources"
    "01_watch_app_connectiq/docs"
    "02_android_companion/app/build.gradle"
    "02_android_companion/build.gradle"
    "02_android_companion/AndroidManifest.xml"
    "02_android_companion/app/src/main/java"
    "02_android_companion/app/src/main/res"
    "03_python_analysis/main.py"
    "03_python_analysis/requirements.txt"
    "03_python_analysis/modules"
    "03_python_analysis/sample_data/sample_session.jsonl"
    "04_docs"
    "05_tests/test_python"
    "05_tests/test_plan.md"
    "05_tests/test_cases.md"
    "05_tests/checklist_integration.md"
    "05_tests/test_report.md"
    "06_release/RELEASE_NOTES_v${VERSION}.md"
    "06_release/CHECKLIST_MISE_EN_ROUTE.md"
    "README.md"
    ".gitignore"
)

# ── Files and directories to exclude ──────────────────────────────────────────

EXCLUDES=(
    "*.pyc"
    "__pycache__"
    ".DS_Store"
    "Thumbs.db"
    "*.tmp"
    "*.log"
    ".gradle"
    "build/"
    ".idea/"
    "*.iml"
    "output/"
    "*.prg"
    "*.iq"
    "ConnectIQ.aar"
    "local.properties"
    "*.jks"
    "*.keystore"
)

# ── Build exclude pattern for zip ─────────────────────────────────────────────

EXCLUDE_ARGS=()
for excl in "${EXCLUDES[@]}"; do
    EXCLUDE_ARGS+=("-x" "*/${excl}" "-x" "${excl}")
done

# ── Remove old archive if exists ──────────────────────────────────────────────

if [[ -f "$ARCHIVE_PATH" ]]; then
    echo "Removing old archive: $ARCHIVE_PATH"
    rm "$ARCHIVE_PATH"
fi

# ── Create the archive ────────────────────────────────────────────────────────

echo ""
echo "Creating archive..."
cd "$PROJECT_ROOT"

# Build the list of existing paths only
EXISTING_PATHS=()
for item in "${INCLUDES[@]}"; do
    if [[ -e "$item" ]]; then
        EXISTING_PATHS+=("$item")
    else
        echo "  WARNING: Skipping missing path: $item"
    fi
done

if [[ ${#EXISTING_PATHS[@]} -eq 0 ]]; then
    echo "ERROR: No files found to archive."
    exit 1
fi

# Run zip
zip -r "$ARCHIVE_PATH" "${EXISTING_PATHS[@]}" "${EXCLUDE_ARGS[@]}"

# ── Report ────────────────────────────────────────────────────────────────────

echo ""
echo "============================================================"
echo "  Archive created successfully!"
echo ""
echo "  File    : $ARCHIVE_PATH"
echo "  Size    : $(du -sh "$ARCHIVE_PATH" | cut -f1)"
echo "  Contents:"
zip -sf "$ARCHIVE_PATH" | head -50
echo "============================================================"

# ── Integrity check ───────────────────────────────────────────────────────────

echo ""
echo "Verifying archive integrity..."
if zip -T "$ARCHIVE_PATH"; then
    echo "Archive integrity: OK"
else
    echo "ERROR: Archive integrity check failed!"
    exit 1
fi

echo ""
echo "Done. Distribute: $ARCHIVE_PATH"
