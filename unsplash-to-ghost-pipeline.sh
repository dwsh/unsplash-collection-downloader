#!/bin/bash

set -e

SCRIPT_NAME=$(basename "$0")
DOWNLOAD_DIR=""
DEFAULT_COUNT=10
UNSPLASH_API_URL="https://api.unsplash.com"
CSV_FILE=""
JSON_FILE=""
GEMINI_MODEL="gemini-1.5-flash"
RATE_LIMIT_DELAY=6
TOKEN_WINDOW_START=0
TOKEN_COUNT=0
TEMPERATURE=0.7

# Ghost CMS variables
GHOST_API_KEY=""
GHOST_URL=""
CONTENT_TYPE="post"
STATUS="draft"
AUTHOR_ID=""
DRY_RUN="false"
VERBOSE="false"

# Pipeline control
SKIP_DOWNLOAD="false"
SKIP_CONTENT_GENERATION="false"
SKIP_GHOST_EXPORT="false"

usage() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

Complete pipeline: Download Unsplash images → Generate content → Export to Ghost CMS

REQUIRED OPTIONS:
  -k, --unsplash-api-key KEY    Unsplash API access key
  -i, --collection-id ID        Collection ID to download from
  -g, --gemini-api-key KEY      Gemini API key for content generation
  -G, --ghost-api-key KEY       Ghost Admin API key (id:secret format)
  -u, --ghost-url URL           Ghost site URL (e.g., https://yourblog.com)

OPTIONAL SETTINGS:
  -c, --count NUMBER            Number of images to download (default: $DEFAULT_COUNT)
  -d, --dir DIRECTORY           Download directory (default: [collection_id]_[collection_slug])
  -o, --output CSV_FILE         CSV output filename (default: image_metadata.csv in download dir)
  -j, --json JSON_FILE          JSON output filename (default: image_metadata.json in download dir)
  -m, --gemini-model MODEL      Gemini model to use (default: $GEMINI_MODEL)
  -t, --temperature NUM         Model temperature 0.0-1.0 (default: $TEMPERATURE)
  --delay SECONDS               Delay between API requests (default: auto based on model)
  --ghost-type TYPE             Content type: 'post' or 'page' (default: post)
  --ghost-status STATUS         Publication status: 'draft' or 'published' (default: draft)
  --ghost-author AUTHOR_ID      Author ID (optional)

PIPELINE CONTROL:
  --skip-download               Skip Unsplash download step (use existing CSV)
  --skip-content                Skip content generation step (use existing JSON)
  --skip-ghost                  Skip Ghost CMS export step
  --dry-run                     Show what would be created without actually posting to Ghost
  -v, --verbose                 Enable verbose output

OTHER OPTIONS:
  -h, --help                    Show this help message

EXAMPLES:
  # Full pipeline - download, generate content, export to Ghost
  $SCRIPT_NAME -k UNSPLASH_KEY -i 12345678 -g GEMINI_KEY -G "ghost_id:ghost_secret" -u "https://myblog.com"
  
  # Download 50 images and create published posts
  $SCRIPT_NAME -k UNSPLASH_KEY -i 12345678 -c 50 -g GEMINI_KEY -G "ghost_id:ghost_secret" -u "https://myblog.com" --ghost-status published
  
  # Skip download, use existing CSV file
  $SCRIPT_NAME --skip-download -d existing_folder -g GEMINI_KEY -G "ghost_id:ghost_secret" -u "https://myblog.com"
  
  # Generate content only (no Ghost export)
  $SCRIPT_NAME -k UNSPLASH_KEY -i 12345678 -g GEMINI_KEY --skip-ghost

PIPELINE STEPS:
  1. Download images from Unsplash collection (creates CSV with metadata)
  2. Generate blog content using Gemini AI (creates JSON with titles and content)
  3. Upload images and create posts/pages in Ghost CMS

API KEYS:
  - Unsplash: Get from https://unsplash.com/developers
  - Gemini: Get from https://makersuite.google.com/app/apikey
  - Ghost: Get from Ghost Admin > Settings > Integrations > Add custom integration

EOF
}

log() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    fi
}

error() {
    echo "ERROR: $1" >&2
    exit 1
}

check_dependencies() {
    local missing=()
    
    if ! command -v curl &> /dev/null; then
        missing+=("curl")
    fi
    
    if ! command -v jq &> /dev/null; then
        missing+=("jq")
    fi
    
    if ! command -v python3 &> /dev/null; then
        missing+=("python3")
    fi
    
    if ! command -v openssl &> /dev/null; then
        missing+=("openssl")
    fi
    
    if ! command -v base64 &> /dev/null; then
        missing+=("base64")
    fi
    
    if [ ${#missing[@]} -ne 0 ]; then
        echo "Error: Missing required dependencies: ${missing[*]}"
        echo "Please install them and try again."
        echo ""
        echo "On macOS: brew install ${missing[*]}"
        echo "On Ubuntu/Debian: sudo apt-get install ${missing[*]}"
        exit 1
    fi
    
    # Check Python modules
    python3 -c "import json, base64, time, hashlib, hmac, csv" 2>/dev/null || error "Required Python modules not available"
}

escape_csv() {
    local value="$1"
    if [[ "$value" == *","* ]] || [[ "$value" == *"\""* ]] || [[ "$value" == *$'\n'* ]]; then
        value="\"${value//\"/\"\"}\""
    fi
    echo "$value"
}

# ============================================================================
# UNSPLASH DOWNLOAD FUNCTIONS
# ============================================================================

download_unsplash_collection() {
    local api_key="$1"
    local collection_id="$2"
    local count="$3"
    
    echo "=== STEP 1: DOWNLOADING UNSPLASH COLLECTION ==="
    echo "Collection ID: $collection_id"
    echo "Count: $count"
    echo ""
    
    local download_args=()
    download_args+=("-k" "$api_key")
    download_args+=("-i" "$collection_id")
    download_args+=("-c" "$count")
    
    if [[ -n "$DOWNLOAD_DIR" ]]; then
        download_args+=("-d" "$DOWNLOAD_DIR")
    fi
    
    if [[ -n "$CSV_FILE" ]]; then
        download_args+=("-o" "$CSV_FILE")
    fi
    
    log "Calling: ./download_unsplash.sh ${download_args[*]}"
    
    if ! ./download_unsplash.sh "${download_args[@]}"; then
        error "Failed to download Unsplash collection"
    fi
    
    # Extract download directory and CSV file from download script output if not set
    if [[ -z "$DOWNLOAD_DIR" ]]; then
        # Download script creates directory based on collection name
        DOWNLOAD_DIR=$(ls -td ${collection_id}_* | head -1 2>/dev/null || echo "")
        if [[ -z "$DOWNLOAD_DIR" ]]; then
            error "Could not determine download directory"
        fi
    fi
    
    if [[ -z "$CSV_FILE" ]]; then
        CSV_FILE="$DOWNLOAD_DIR/image_metadata.csv"
    fi
    
    echo "Download directory: $DOWNLOAD_DIR"
    echo "CSV file: $CSV_FILE"
    echo ""
}

# ============================================================================
# GEMINI CONTENT GENERATION FUNCTIONS
# ============================================================================

get_rate_limit_delay() {
    local model="$1"
    
    case "$model" in
        "gemini-2.5-pro")
            echo 12
            ;;
        "gemini-2.5-flash")
            echo 6
            ;;
        "gemini-2.5-flash-lite")
            echo 4
            ;;
        "gemini-2.0-flash")
            echo 4
            ;;
        "gemini-1.5-flash"|"gemini-1.5-pro")
            echo 6
            ;;
        *)
            echo 6
            ;;
    esac
}

generate_content_from_images() {
    local input_csv="$1"
    local output_json="$2"
    
    echo "=== STEP 2: GENERATING CONTENT WITH GEMINI AI ==="
    echo "Input CSV: $input_csv"
    echo "Output JSON: $output_json"
    echo ""
    
    local content_args=()
    content_args+=("-f" "$input_csv")
    content_args+=("-o" "$output_json")
    content_args+=("-k" "$GEMINI_API_KEY")
    content_args+=("-m" "$GEMINI_MODEL")
    content_args+=("-t" "$TEMPERATURE")
    content_args+=("-d" "$RATE_LIMIT_DELAY")
    
    log "Calling: ./generate-content-from-images.sh ${content_args[*]}"
    
    if ! ./generate-content-from-images.sh "${content_args[@]}"; then
        error "Failed to generate content with Gemini AI"
    fi
    
    echo "Content generation complete!"
    echo "Output saved to: $output_json"
    echo ""
}

# ============================================================================
# GHOST CMS EXPORT FUNCTIONS
# ============================================================================

export_to_ghost() {
    local input_json="$1"
    
    echo "=== STEP 3: EXPORTING TO GHOST CMS ==="
    echo "Input JSON: $input_json"
    echo "Ghost URL: $GHOST_URL"
    echo "Content Type: $CONTENT_TYPE"
    echo "Status: $STATUS"
    [[ "$DRY_RUN" == "true" ]] && echo "Mode: DRY RUN"
    echo ""
    
    local ghost_args=()
    ghost_args+=("-f" "$input_json")
    ghost_args+=("-k" "$GHOST_API_KEY")
    ghost_args+=("-u" "$GHOST_URL")
    ghost_args+=("-t" "$CONTENT_TYPE")
    ghost_args+=("-s" "$STATUS")
    
    if [[ -n "$AUTHOR_ID" ]]; then
        ghost_args+=("-a" "$AUTHOR_ID")
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        ghost_args+=("--dry-run")
    fi
    
    if [[ "$VERBOSE" == "true" ]]; then
        ghost_args+=("-v")
    fi
    
    log "Calling: ./export-to-ghost.sh ${ghost_args[*]}"
    
    if ! ./export-to-ghost.sh "${ghost_args[@]}"; then
        error "Failed to export to Ghost CMS"
    fi
    
    echo "Ghost export complete!"
    echo ""
}

# ============================================================================
# MAIN PIPELINE FUNCTION
# ============================================================================

main() {
    check_dependencies
    
    # Validation
    if [[ "$SKIP_DOWNLOAD" == "false" ]]; then
        [[ -z "$UNSPLASH_API_KEY" ]] && error "Unsplash API key is required (-k)"
        [[ -z "$COLLECTION_ID" ]] && error "Collection ID is required (-i)"
    fi
    
    if [[ "$SKIP_CONTENT_GENERATION" == "false" ]]; then
        [[ -z "$GEMINI_API_KEY" ]] && error "Gemini API key is required (-g)"
    fi
    
    if [[ "$SKIP_GHOST_EXPORT" == "false" ]]; then
        [[ -z "$GHOST_API_KEY" ]] && error "Ghost API key is required (-G)"
        [[ -z "$GHOST_URL" ]] && error "Ghost URL is required (-u)"
        
        if [[ "$GHOST_API_KEY" != *":"* ]]; then
            error "Ghost API key must be in format 'id:secret'"
        fi
        
        GHOST_URL="${GHOST_URL%/}"
    fi
    
    # Set intelligent rate limiting delay if not specified
    if [[ "$RATE_LIMIT_DELAY" -eq 6 ]]; then
        RATE_LIMIT_DELAY=$(get_rate_limit_delay "$GEMINI_MODEL")
        echo "Using model-specific rate limit: ${RATE_LIMIT_DELAY}s delay for $GEMINI_MODEL"
    fi
    
    # Pipeline execution
    echo "=========================================="
    echo "UNSPLASH TO GHOST CMS PIPELINE"
    echo "=========================================="
    echo ""
    
    # Step 1: Download from Unsplash
    if [[ "$SKIP_DOWNLOAD" == "false" ]]; then
        download_unsplash_collection "$UNSPLASH_API_KEY" "$COLLECTION_ID" "$COUNT"
    else
        echo "=== STEP 1: SKIPPED (using existing files) ==="
        if [[ -z "$DOWNLOAD_DIR" ]]; then
            error "Download directory must be specified when skipping download (-d)"
        fi
        if [[ -z "$CSV_FILE" ]]; then
            CSV_FILE="$DOWNLOAD_DIR/image_metadata.csv"
        fi
        echo "Using existing CSV: $CSV_FILE"
        echo ""
    fi
    
    # Step 2: Generate content with Gemini
    if [[ "$SKIP_CONTENT_GENERATION" == "false" ]]; then
        if [[ -z "$JSON_FILE" ]]; then
            local csv_dir=$(dirname "$CSV_FILE")
            local csv_base=$(basename "$CSV_FILE" .csv)
            JSON_FILE="$csv_dir/${csv_base}.json"
        fi
        generate_content_from_images "$CSV_FILE" "$JSON_FILE"
    else
        echo "=== STEP 2: SKIPPED (using existing JSON) ==="
        if [[ -z "$JSON_FILE" ]]; then
            local csv_dir=$(dirname "$CSV_FILE")
            local csv_base=$(basename "$CSV_FILE" .csv)
            JSON_FILE="$csv_dir/${csv_base}.json"
        fi
        echo "Using existing JSON: $JSON_FILE"
        echo ""
    fi
    
    # Step 3: Export to Ghost CMS
    if [[ "$SKIP_GHOST_EXPORT" == "false" ]]; then
        export_to_ghost "$JSON_FILE"
    else
        echo "=== STEP 3: SKIPPED ==="
        echo ""
    fi
    
    echo "=========================================="
    echo "PIPELINE COMPLETE!"
    echo "=========================================="
}

# ============================================================================
# COMMAND LINE ARGUMENT PARSING
# ============================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        -k|--unsplash-api-key)
            UNSPLASH_API_KEY="$2"
            shift 2
            ;;
        -i|--collection-id)
            COLLECTION_ID="$2"
            shift 2
            ;;
        -c|--count)
            COUNT="$2"
            shift 2
            ;;
        -d|--dir)
            DOWNLOAD_DIR="$2"
            shift 2
            ;;
        -o|--output)
            CSV_FILE="$2"
            shift 2
            ;;
        -j|--json)
            JSON_FILE="$2"
            shift 2
            ;;
        -g|--gemini-api-key)
            GEMINI_API_KEY="$2"
            shift 2
            ;;
        -m|--gemini-model)
            GEMINI_MODEL="$2"
            shift 2
            ;;
        -t|--temperature)
            TEMPERATURE="$2"
            shift 2
            ;;
        --delay)
            RATE_LIMIT_DELAY="$2"
            shift 2
            ;;
        -G|--ghost-api-key)
            GHOST_API_KEY="$2"
            shift 2
            ;;
        -u|--ghost-url)
            GHOST_URL="$2"
            shift 2
            ;;
        --ghost-type)
            CONTENT_TYPE="$2"
            shift 2
            ;;
        --ghost-status)
            STATUS="$2"
            shift 2
            ;;
        --ghost-author)
            AUTHOR_ID="$2"
            shift 2
            ;;
        --skip-download)
            SKIP_DOWNLOAD="true"
            shift
            ;;
        --skip-content)
            SKIP_CONTENT_GENERATION="true"
            shift
            ;;
        --skip-ghost)
            SKIP_GHOST_EXPORT="true"
            shift
            ;;
        --dry-run)
            DRY_RUN="true"
            shift
            ;;
        -v|--verbose)
            VERBOSE="true"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: Unknown option $1"
            usage
            exit 1
            ;;
    esac
done

# Execute main function
main