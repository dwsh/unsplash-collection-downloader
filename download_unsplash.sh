#!/bin/bash

SCRIPT_NAME=$(basename "$0")
DOWNLOAD_DIR=""  # Will be set based on collection info
DEFAULT_COUNT=10
UNSPLASH_API_URL="https://api.unsplash.com"
CSV_FILE=""  # Will be set based on download directory

usage() {
    echo "Usage: $SCRIPT_NAME [OPTIONS]"
    echo ""
    echo "Download images from Unsplash collections with metadata export"
    echo ""
    echo "Options:"
    echo "  -k, --api-key KEY      Unsplash API access key (required)"
    echo "  -i, --collection-id ID Collection ID to download from (required)"
    echo "  -c, --count NUMBER     Number of images to download (default: $DEFAULT_COUNT)"
    echo "  -d, --dir DIRECTORY    Download directory (default: [collection_id]_[collection_slug])"
    echo "  -o, --output CSV_FILE  CSV output filename (default: image_metadata.csv in download dir)"
    echo "  -h, --help             Show this help message"
    echo ""
    echo "Examples:"
    echo "  $SCRIPT_NAME -k YOUR_API_KEY -i 12345678 -c 20"
    echo "  $SCRIPT_NAME --api-key YOUR_KEY --collection-id 87654321 --count 50 --dir ~/Pictures"
    echo ""
    echo "Note: Get your API key from https://unsplash.com/developers"
    echo "      Find collection IDs in Unsplash collection URLs"
}

check_dependencies() {
    local missing=()
    
    if ! command -v curl &> /dev/null; then
        missing+=("curl")
    fi
    
    if ! command -v jq &> /dev/null; then
        missing+=("jq")
    fi
    
    if [ ${#missing[@]} -ne 0 ]; then
        echo "Error: Missing required dependencies: ${missing[*]}"
        echo "Please install them and try again."
        echo ""
        echo "On macOS: brew install ${missing[*]}"
        echo "On Ubuntu/Debian: sudo apt-get install ${missing[*]}"
        exit 1
    fi
}

escape_csv() {
    local value="$1"
    if [[ "$value" == *","* ]] || [[ "$value" == *"\""* ]] || [[ "$value" == *$'\n'* ]]; then
        value="\"${value//\"/\"\"}\""
    fi
    echo "$value"
}

download_image() {
    local url="$1"
    local filename="$2"
    local filepath="$DOWNLOAD_DIR/$filename"
    
    echo "Downloading: $filename"
    
    if curl -L -o "$filepath" "$url" --silent --show-error; then
        echo "✓ Downloaded: $filename"
        return 0
    else
        echo "✗ Failed to download: $filename"
        return 1
    fi
}

fetch_collection_info() {
    local collection_id="$1"
    local api_key="$2"
    
    local url="${UNSPLASH_API_URL}/collections/${collection_id}?client_id=${api_key}"
    
    curl -s "$url" -H "Accept: application/json"
}

fetch_collection_photos() {
    local collection_id="$1"
    local per_page="$2"
    local page="$3"
    local api_key="$4"
    
    local url="${UNSPLASH_API_URL}/collections/${collection_id}/photos?per_page=${per_page}&page=${page}&client_id=${api_key}"
    
    curl -s "$url" -H "Accept: application/json"
}

fetch_all_collection_photos() {
    local collection_id="$1"
    local total_photos="$2"
    local max_photos="$3"
    local api_key="$4"
    local per_page=30
    local page=1
    local temp_file="/tmp/unsplash_photos_$$.json"
    local downloaded_count=0
    
    # Initialize with empty array
    echo "[]" > "$temp_file"
    
    echo "Fetching all photos from collection (total: $total_photos, downloading: $max_photos)..." >&2
    
    while [[ $downloaded_count -lt $max_photos ]]; do
        echo "Fetching page $page..." >&2
        local photos_json=$(fetch_collection_photos "$collection_id" "$per_page" "$page" "$api_key")
        
        if [[ -z "$photos_json" ]] || [[ "$photos_json" == "null" ]]; then
            echo "Error: Failed to fetch page $page" >&2
            break
        fi
        
        if echo "$photos_json" | jq -e '.errors' > /dev/null 2>&1; then
            echo "Error on page $page:" >&2
            echo "$photos_json" | jq -r '.errors[].message' 2>/dev/null >&2
            break
        fi
        
        local page_count=$(echo "$photos_json" | jq '. | length')
        
        if [[ "$page_count" -eq 0 ]]; then
            echo "No more photos found. Finished at page $((page-1))" >&2
            break
        fi
        
        echo "Found $page_count photos on page $page" >&2
        
        # If we would exceed max_photos, slice the array
        local remaining=$((max_photos - downloaded_count))
        if [[ $page_count -gt $remaining ]]; then
            echo "Limiting to $remaining photos to reach target of $max_photos" >&2
            photos_json=$(echo "$photos_json" | jq ".[:$remaining]")
            page_count=$remaining
        fi
        
        # Merge photos into temp file
        jq --argjson new "$photos_json" '. + $new' "$temp_file" > "${temp_file}.tmp" && mv "${temp_file}.tmp" "$temp_file"
        downloaded_count=$((downloaded_count + page_count))
        
        echo "Total photos fetched so far: $downloaded_count" >&2
        
        # If we reached our target or got less than per_page photos, we're done
        if [[ $downloaded_count -ge $max_photos ]] || [[ $page_count -lt $per_page ]]; then
            break
        fi
        
        page=$((page + 1))
        
        # Rate limiting - wait 1 second between requests
        sleep 1
    done
    
    cat "$temp_file"
    rm -f "$temp_file" "${temp_file}.tmp"
}

API_KEY=""
COLLECTION_ID=""
COUNT=$DEFAULT_COUNT

while [[ $# -gt 0 ]]; do
    case $1 in
        -k|--api-key)
            API_KEY="$2"
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

check_dependencies

if [[ -z "$API_KEY" ]]; then
    echo "Error: API key is required. Use -k or --api-key"
    echo "Get your API key from: https://unsplash.com/developers"
    exit 1
fi

if [[ -z "$COLLECTION_ID" ]]; then
    echo "Error: Collection ID is required. Use -i or --collection-id"
    echo "Find collection IDs in Unsplash collection URLs"
    exit 1
fi

if [[ ! "$COUNT" =~ ^[0-9]+$ ]] || [[ "$COUNT" -le 0 ]]; then
    echo "Error: Count must be a positive integer"
    exit 1
fi

# Remove the 30-photo limit since we now support pagination

echo "Fetching photos from Unsplash collection: $COLLECTION_ID"
echo ""

echo "Checking collection info..."
COLLECTION_INFO=$(fetch_collection_info "$COLLECTION_ID" "$API_KEY")

if echo "$COLLECTION_INFO" | jq -e '.errors' > /dev/null 2>&1; then
    echo "Error: Collection not found or access denied:"
    echo "$COLLECTION_INFO" | jq -r '.errors[].message' 2>/dev/null || echo "Unknown collection error"
    exit 1
fi

COLLECTION_TITLE=$(echo "$COLLECTION_INFO" | jq -r '.title // "Unknown"')
TOTAL_PHOTOS=$(echo "$COLLECTION_INFO" | jq -r '.total_photos // 0')

# Set default directory name if not specified
if [[ -z "$DOWNLOAD_DIR" ]]; then
    # Create slug from title for filesystem safety
    CLEAN_TITLE=$(echo "$COLLECTION_TITLE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-zA-Z0-9]/_/g' | sed 's/__*/_/g' | sed 's/^_\|_$//g')
    DOWNLOAD_DIR="${COLLECTION_ID}_${CLEAN_TITLE}"
fi

# Set default CSV file if not specified  
if [[ -z "$CSV_FILE" ]]; then
    CSV_FILE="$DOWNLOAD_DIR/image_metadata.csv"
fi

echo "Collection: $COLLECTION_TITLE"
echo "Total photos in collection: $TOTAL_PHOTOS"
echo "Download directory: $DOWNLOAD_DIR"
echo "CSV output: $CSV_FILE"

if [[ "$TOTAL_PHOTOS" -eq 0 ]]; then
    echo "Error: Collection is empty"
    exit 1
fi

# Create download directory
mkdir -p "$DOWNLOAD_DIR"

echo ""
# Determine how many photos to download (all or limited by count)
PHOTOS_TO_DOWNLOAD=$COUNT
if [[ $COUNT -gt $TOTAL_PHOTOS ]]; then
    PHOTOS_TO_DOWNLOAD=$TOTAL_PHOTOS
    echo "Requested $COUNT photos, but collection only has $TOTAL_PHOTOS. Downloading all $TOTAL_PHOTOS photos."
fi

PHOTOS_JSON=$(fetch_all_collection_photos "$COLLECTION_ID" "$TOTAL_PHOTOS" "$PHOTOS_TO_DOWNLOAD" "$API_KEY")

if [[ -z "$PHOTOS_JSON" ]] || [[ "$PHOTOS_JSON" == "null" ]]; then
    echo "Error: Failed to fetch collection data. Check your API key and collection ID."
    exit 1
fi

if echo "$PHOTOS_JSON" | jq -e '.errors' > /dev/null 2>&1; then
    echo "Error: API returned errors:"
    echo "$PHOTOS_JSON" | jq -r '.errors[].message' 2>/dev/null || echo "Unknown API error"
    echo "Full response: $PHOTOS_JSON"
    exit 1
fi

# Debug: Check if response is valid JSON
if ! echo "$PHOTOS_JSON" | jq . > /dev/null 2>&1; then
    echo "Error: Invalid JSON response:"
    echo "$PHOTOS_JSON" | head -c 500
    exit 1
fi

PHOTO_COUNT=$(echo "$PHOTOS_JSON" | jq '. | length')

if [[ "$PHOTO_COUNT" -eq 0 ]]; then
    echo "Error: No photos found in collection $COLLECTION_ID"
    exit 1
fi

echo "Found $PHOTO_COUNT photos in collection"
echo ""

cat > "$CSV_FILE" << 'EOF'
filename,id,description,alt_description,photographer,photographer_username,width,height,likes,downloads,created_at,updated_at,color,blur_hash,download_url,photo_url
EOF

SUCCESSFUL=0
FAILED=0

for i in $(seq 0 $((PHOTO_COUNT - 1))); do
    PHOTO=$(echo "$PHOTOS_JSON" | jq ".[$i]")
    
    ID=$(echo "$PHOTO" | jq -r '.id')
    DESCRIPTION=$(echo "$PHOTO" | jq -r '.description // ""')
    ALT_DESCRIPTION=$(echo "$PHOTO" | jq -r '.alt_description // ""')
    PHOTOGRAPHER=$(echo "$PHOTO" | jq -r '.user.name // ""')
    PHOTOGRAPHER_USERNAME=$(echo "$PHOTO" | jq -r '.user.username // ""')
    WIDTH=$(echo "$PHOTO" | jq -r '.width')
    HEIGHT=$(echo "$PHOTO" | jq -r '.height')
    LIKES=$(echo "$PHOTO" | jq -r '.likes')
    DOWNLOADS=$(echo "$PHOTO" | jq -r '.downloads // 0')
    CREATED_AT=$(echo "$PHOTO" | jq -r '.created_at')
    UPDATED_AT=$(echo "$PHOTO" | jq -r '.updated_at')
    COLOR=$(echo "$PHOTO" | jq -r '.color // ""')
    BLUR_HASH=$(echo "$PHOTO" | jq -r '.blur_hash // ""')
    DOWNLOAD_URL=$(echo "$PHOTO" | jq -r '.urls.full')
    PHOTO_URL=$(echo "$PHOTO" | jq -r '.links.html')
    
    FILENAME="${ID}.jpg"
    
    DESCRIPTION_ESC=$(escape_csv "$DESCRIPTION")
    ALT_DESCRIPTION_ESC=$(escape_csv "$ALT_DESCRIPTION")
    PHOTOGRAPHER_ESC=$(escape_csv "$PHOTOGRAPHER")
    BLUR_HASH_ESC=$(escape_csv "$BLUR_HASH")
    
    echo "$FILENAME,$ID,$DESCRIPTION_ESC,$ALT_DESCRIPTION_ESC,$PHOTOGRAPHER_ESC,$PHOTOGRAPHER_USERNAME,$WIDTH,$HEIGHT,$LIKES,$DOWNLOADS,$CREATED_AT,$UPDATED_AT,$COLOR,$BLUR_HASH_ESC,$DOWNLOAD_URL,$PHOTO_URL" >> "$CSV_FILE"
    
    if download_image "$DOWNLOAD_URL" "$FILENAME"; then
        ((SUCCESSFUL++))
    else
        ((FAILED++))
    fi
    
    if [[ $i -lt $((PHOTO_COUNT - 1)) ]]; then
        sleep 1
    fi
done

echo ""
echo "Download complete!"
echo "Successfully downloaded: $SUCCESSFUL images"
if [[ $FAILED -gt 0 ]]; then
    echo "Failed downloads: $FAILED images"
fi
echo "Images saved to: $DOWNLOAD_DIR"
echo "Metadata exported to: $CSV_FILE"