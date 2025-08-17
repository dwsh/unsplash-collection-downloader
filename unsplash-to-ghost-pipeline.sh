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
    
    echo "[]" > "$temp_file"
    
    echo "Fetching all photos from collection (total: $total_photos, downloading: $max_photos)..."
    
    while [[ $downloaded_count -lt $max_photos ]]; do
        echo "Fetching page $page..."
        local photos_json=$(fetch_collection_photos "$collection_id" "$per_page" "$page" "$api_key")
        
        if [[ -z "$photos_json" ]] || [[ "$photos_json" == "null" ]]; then
            echo "Error: Failed to fetch page $page"
            break
        fi
        
        if echo "$photos_json" | jq -e '.errors' > /dev/null 2>&1; then
            echo "Error on page $page:"
            echo "$photos_json" | jq -r '.errors[].message' 2>/dev/null
            break
        fi
        
        local page_count=$(echo "$photos_json" | jq '. | length')
        
        if [[ "$page_count" -eq 0 ]]; then
            echo "No more photos found. Finished at page $((page-1))"
            break
        fi
        
        echo "Found $page_count photos on page $page"
        
        local remaining=$((max_photos - downloaded_count))
        if [[ $page_count -gt $remaining ]]; then
            echo "Limiting to $remaining photos to reach target of $max_photos"
            photos_json=$(echo "$photos_json" | jq ".[:$remaining]")
            page_count=$remaining
        fi
        
        jq --argjson new "$photos_json" '. + $new' "$temp_file" > "${temp_file}.tmp" && mv "${temp_file}.tmp" "$temp_file"
        downloaded_count=$((downloaded_count + page_count))
        
        echo "Total photos fetched so far: $downloaded_count"
        
        if [[ $downloaded_count -ge $max_photos ]] || [[ $page_count -lt $per_page ]]; then
            break
        fi
        
        page=$((page + 1))
        sleep 1
    done
    
    cat "$temp_file"
    rm -f "$temp_file" "${temp_file}.tmp"
}

download_unsplash_collection() {
    local api_key="$1"
    local collection_id="$2"
    local count="$3"
    
    echo "=== STEP 1: DOWNLOADING UNSPLASH COLLECTION ==="
    echo "Collection ID: $collection_id"
    echo "Count: $count"
    echo ""
    
    echo "Checking collection info..."
    COLLECTION_INFO=$(fetch_collection_info "$collection_id" "$api_key")
    
    if echo "$COLLECTION_INFO" | jq -e '.errors' > /dev/null 2>&1; then
        error "Collection not found or access denied: $(echo "$COLLECTION_INFO" | jq -r '.errors[].message')"
    fi
    
    if ! echo "$COLLECTION_INFO" | jq . > /dev/null 2>&1; then
        error "Invalid JSON response from collection info API"
    fi
    
    COLLECTION_TITLE=$(echo "$COLLECTION_INFO" | jq -r '.title // "Unknown"')
    TOTAL_PHOTOS=$(echo "$COLLECTION_INFO" | jq -r '.total_photos // 0')
    
    if [[ -z "$DOWNLOAD_DIR" ]]; then
        CLEAN_TITLE=$(echo "$COLLECTION_TITLE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-zA-Z0-9]/_/g' | sed 's/__*/_/g' | sed 's/^_\|_$//g')
        DOWNLOAD_DIR="${collection_id}_${CLEAN_TITLE}"
    fi
    
    if [[ -z "$CSV_FILE" ]]; then
        CSV_FILE="$DOWNLOAD_DIR/image_metadata.csv"
    fi
    
    echo "Collection: $COLLECTION_TITLE"
    echo "Total photos in collection: $TOTAL_PHOTOS"
    echo "Download directory: $DOWNLOAD_DIR"
    echo "CSV output: $CSV_FILE"
    
    if [[ "$TOTAL_PHOTOS" -eq 0 ]]; then
        error "Collection is empty"
    fi
    
    mkdir -p "$DOWNLOAD_DIR"
    
    PHOTOS_TO_DOWNLOAD=$count
    if [[ $count -gt $TOTAL_PHOTOS ]]; then
        PHOTOS_TO_DOWNLOAD=$TOTAL_PHOTOS
        echo "Requested $count photos, but collection only has $TOTAL_PHOTOS. Downloading all $TOTAL_PHOTOS photos."
    fi
    
    PHOTOS_JSON=$(fetch_all_collection_photos "$collection_id" "$TOTAL_PHOTOS" "$PHOTOS_TO_DOWNLOAD" "$api_key")
    
    if [[ -z "$PHOTOS_JSON" ]] || [[ "$PHOTOS_JSON" == "null" ]]; then
        error "Failed to fetch collection data. Check your API key and collection ID."
    fi
    
    PHOTO_COUNT=$(echo "$PHOTOS_JSON" | jq '. | length')
    
    if [[ "$PHOTO_COUNT" -eq 0 ]]; then
        error "No photos found in collection $collection_id"
    fi
    
    echo "Found $PHOTO_COUNT photos in collection"
    echo ""
    
    cat > "$CSV_FILE" << 'EOF'
filename,id,description,alt_description,photographer,photographer_username,width,height,likes,downloads,created_at,updated_at,color,blur_hash,download_url,photo_url
EOF
    
    local successful=0
    local failed=0
    
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
            ((successful++))
        else
            ((failed++))
        fi
        
        if [[ $i -lt $((PHOTO_COUNT - 1)) ]]; then
            sleep 1
        fi
    done
    
    echo ""
    echo "Download complete!"
    echo "Successfully downloaded: $successful images"
    if [[ $failed -gt 0 ]]; then
        echo "Failed downloads: $failed images"
    fi
    echo "Images saved to: $DOWNLOAD_DIR"
    echo "Metadata exported to: $CSV_FILE"
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

get_tpm_limit() {
    local model="$1"
    
    case "$model" in
        "gemini-2.5-pro"|"gemini-2.5-flash"|"gemini-2.5-flash-lite")
            echo 250000
            ;;
        "gemini-2.0-flash"|"gemini-2.0-flash-lite")
            echo 1000000
            ;;
        "gemini-1.5-flash"|"gemini-1.5-pro")
            echo 200000
            ;;
        *)
            echo 200000
            ;;
    esac
}

estimate_tokens() {
    local text="$1"
    local image_path="$2"
    
    local char_count=${#text}
    local text_tokens=$((char_count / 4))
    
    local word_count=$(echo "$text" | wc -w | tr -d ' ')
    local word_based_tokens=$((word_count * 100 / 70))
    
    if [[ $word_based_tokens -gt $text_tokens ]]; then
        text_tokens=$word_based_tokens
    fi
    
    local image_tokens=258
    
    if [[ -f "$image_path" ]]; then
        echo $((text_tokens + image_tokens))
    else
        echo $text_tokens
    fi
}

check_token_limit() {
    local estimated_tokens="$1"
    local model="$2"
    local current_time=$(date +%s)
    
    if [[ $((current_time - TOKEN_WINDOW_START)) -ge 60 ]]; then
        TOKEN_WINDOW_START=$current_time
        TOKEN_COUNT=0
    fi
    
    local tpm_limit=$(get_tpm_limit "$model")
    local tokens_after_request=$((TOKEN_COUNT + estimated_tokens))
    
    if [[ $tokens_after_request -gt $tpm_limit ]]; then
        local wait_time=$((60 - (current_time - TOKEN_WINDOW_START)))
        echo "⚠ Token limit would be exceeded! Waiting ${wait_time}s for new minute window..."
        sleep "$wait_time"
        TOKEN_WINDOW_START=$(date +%s)
        TOKEN_COUNT=0
    fi
    
    TOKEN_COUNT=$((TOKEN_COUNT + estimated_tokens))
}

analyze_image_with_gemini() {
    local image_path="$1"
    local image_description="$2"
    local photographer="$3"
    
    if [[ ! -f "$image_path" ]]; then
        echo "Error: Image file not found: $image_path" >&2
        return 1
    fi
    
    local prompt="Analyze this image and create a blog post that would use this image as its thumbnail. 

Image context:
- Description: $image_description
- Photographer: $photographer

Please provide:
1. A compelling blog post title (50-80 characters)
2. HTML blog post content (4-12 paragraphs) that:
   - Never talk about the image explicitely
   - Talk about any theme that can be visualized with the image
   - Uses proper HTML paragraph tags
   - the content should be suitable for web publication
   - Flows naturally from paragraph to paragraph
   - if you need to organize the content into section please use h2, h3 and so on

Format your response as JSON:
{
  \"title\": \"Blog post title here\",
  \"content\": \"<p>First paragraph...</p><p>Second paragraph...</p>...\"
}

Make the content relevant to the image theme and visually appealing for readers."
    
    local estimated_tokens=$(estimate_tokens "$prompt" "$image_path")
    
    echo "  Token breakdown:" >&2
    echo "    Text: ~$((estimated_tokens - 258)) tokens" >&2
    echo "    Image: ~258 tokens" >&2
    echo "    Total estimated: $estimated_tokens tokens" >&2
    
    check_token_limit "$estimated_tokens" "$GEMINI_MODEL"

    local json_file="/tmp/gemini_request_$$.json"
    
    python3 -c "
import json
import base64

# Read and encode image
with open('$image_path', 'rb') as f:
    image_data = base64.b64encode(f.read()).decode('utf-8')

# Create JSON payload
payload = {
    'contents': [{
        'parts': [
            {'text': '''$prompt'''},
            {
                'inline_data': {
                    'mime_type': 'image/jpeg',
                    'data': image_data
                }
            }
        ]
    }],
    'generationConfig': {
        'temperature': $TEMPERATURE,
        'maxOutputTokens': 4000
    }
}

# Write to file
with open('$json_file', 'w') as f:
    json.dump(payload, f)
"
    
    local response=$(curl -s -X POST "https://generativelanguage.googleapis.com/v1beta/models/$GEMINI_MODEL:generateContent?key=$GEMINI_API_KEY" \
        -H "Content-Type: application/json" \
        -d @"$json_file")
    
    rm -f "$json_file"
    
    if [[ -z "$response" ]]; then
        echo "Error: Empty response from Gemini API" >&2
        return 1
    fi
    
    if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
        echo "Error: Gemini API error: $(echo "$response" | jq -r '.error.message')" >&2
        return 1
    fi
    
    local gemini_text=$(echo "$response" | jq -r '.candidates[0].content.parts[0].text' 2>/dev/null)
    
    if [[ -z "$gemini_text" || "$gemini_text" == "null" ]]; then
        echo "Error: Could not extract content from Gemini response" >&2
        return 1
    fi
    
    echo "$gemini_text"
}

generate_content_from_images() {
    local input_csv="$1"
    local output_json="$2"
    
    echo "=== STEP 2: GENERATING CONTENT WITH GEMINI AI ==="
    echo "Input CSV: $input_csv"
    echo "Output JSON: $output_json"
    echo ""
    
    if [[ ! -f "$input_csv" ]]; then
        error "Input CSV file not found: $input_csv"
    fi
    
    local temp_output="/tmp/generate_content_$$.json"
    echo "[" > "$temp_output"
    
    local csv_items=$(python3 << EOF
import csv
import json
import sys

csv_data = []
with open('$input_csv', 'r', encoding='utf-8') as f:
    reader = csv.reader(f)
    header = next(reader)
    
    for row in reader:
        if len(row) >= 16:
            item = {
                'filename': row[0],
                'id': row[1], 
                'description': row[2],
                'alt_description': row[3],
                'photographer': row[4],
                'photographer_username': row[5],
                'width': row[6],
                'height': row[7], 
                'likes': row[8],
                'downloads': row[9],
                'created_at': row[10],
                'updated_at': row[11],
                'color': row[12],
                'blur_hash': row[13],
                'download_url': row[14],
                'photo_url': row[15]
            }
            csv_data.append(item)

print(json.dumps(csv_data))
EOF
)
    
    local image_count=$(echo "$csv_items" | jq '. | length')
    local tpm_limit=$(get_tpm_limit "$GEMINI_MODEL")
    
    echo "Images to process: $image_count"
    echo "Rate limit delay: ${RATE_LIMIT_DELAY}s per request"
    echo "Token limit: $(printf "%'d" $tpm_limit) TPM for $GEMINI_MODEL"
    echo "Temperature: $TEMPERATURE (creativity level)"
    echo ""
    
    TOKEN_WINDOW_START=$(date +%s)
    TOKEN_COUNT=0
    
    local first_item=true
    local processed=0
    local failed=0
    
    for ((i = 0; i < image_count; i++)); do
        echo "Processing item $((i + 1))/$image_count..."
        
        local item_data=$(echo "$csv_items" | jq -r ".[$i]")
        local filename=$(echo "$item_data" | jq -r '.filename')
        local description=$(echo "$item_data" | jq -r '.description')
        local photographer=$(echo "$item_data" | jq -r '.photographer')
        
        local csv_dir=$(dirname "$input_csv")
        local image_path="$csv_dir/$filename"
        
        echo "  Image: $filename"
        echo "  Description: $description"
        echo "  Photographer: $photographer"
        
        local gemini_response=$(analyze_image_with_gemini "$image_path" "$description" "$photographer")
        
        if [[ $? -eq 0 && -n "$gemini_response" ]]; then
            local clean_response=$(echo "$gemini_response" | sed 's/^```json//' | sed 's/```$//')
            
            local blog_title=$(echo "$clean_response" | jq -r '.title // "Untitled"' 2>/dev/null)
            local blog_content=$(echo "$clean_response" | jq -r '.content // ""' 2>/dev/null)
            
            if [[ -n "$blog_title" && -n "$blog_content" && "$blog_title" != "null" && "$blog_content" != "null" ]]; then
                local json_item=$(echo "$item_data" | jq --arg title "$blog_title" --arg content "$blog_content" '. + {blog_title: $title, blog_content: $content}')
                
                if [[ "$first_item" != "true" ]]; then
                    echo "," >> "$temp_output"
                fi
                first_item=false
                
                echo "$json_item" >> "$temp_output"
                
                echo "  ✓ Generated content: $blog_title"
                ((processed++))
            else
                echo "  ✗ Failed to parse Gemini response"
                
                local error_item=$(echo "$item_data" | jq '. + {blog_title: "Error: Failed to parse response", blog_content: ""}')
                
                if [[ "$first_item" != "true" ]]; then
                    echo "," >> "$temp_output"
                fi
                first_item=false
                
                echo "$error_item" >> "$temp_output"
                ((failed++))
            fi
        else
            echo "  ✗ Failed to analyze image"
            
            local error_item=$(echo "$item_data" | jq '. + {blog_title: "Error: Analysis failed", blog_content: ""}')
            
            if [[ "$first_item" != "true" ]]; then
                echo "," >> "$temp_output"
            fi
            first_item=false
            
            echo "$error_item" >> "$temp_output"
            ((failed++))
        fi
        
        echo ""
        
        if [[ $((i + 1)) -lt $image_count ]]; then
            echo "  Waiting ${RATE_LIMIT_DELAY}s to respect API rate limits..."
            sleep "$RATE_LIMIT_DELAY"
        fi
    done
    
    echo "]" >> "$temp_output"
    mv "$temp_output" "$output_json"
    
    echo "Content generation complete!"
    echo "Processed: $processed images"
    echo "Failed: $failed images"
    echo "Output saved to: $output_json"
    echo ""
}

# ============================================================================
# GHOST CMS EXPORT FUNCTIONS
# ============================================================================

generate_jwt_token() {
    local api_key="$1"
    local api_id="${api_key%:*}"
    local api_secret="${api_key#*:}"
    
    log "Generating JWT token for API authentication..."
    
    python3 << EOF
import json
import base64
import time
import hashlib
import hmac

header = {
    "typ": "JWT",
    "alg": "HS256",
    "kid": "$api_id"
}

now = int(time.time())
payload = {
    "iat": now,
    "exp": now + 300,
    "aud": "/admin/"
}

header_encoded = base64.urlsafe_b64encode(json.dumps(header, separators=(',', ':')).encode()).decode().rstrip('=')
payload_encoded = base64.urlsafe_b64encode(json.dumps(payload, separators=(',', ':')).encode()).decode().rstrip('=')

secret_bytes = bytes.fromhex("$api_secret")
message = f"{header_encoded}.{payload_encoded}".encode()
signature = hmac.new(secret_bytes, message, hashlib.sha256).digest()
signature_encoded = base64.urlsafe_b64encode(signature).decode().rstrip('=')

jwt_token = f"{header_encoded}.{payload_encoded}.{signature_encoded}"
print(jwt_token)
EOF
}

upload_image() {
    local image_path="$1"
    local jwt_token="$2"
    
    if [[ ! -f "$image_path" ]]; then
        echo ""
        return
    fi
    
    log "Uploading image: $image_path"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "https://example.com/uploaded-image.jpg"
        return
    fi
    
    local response
    response=$(curl -s -X POST \
        "$GHOST_URL/ghost/api/admin/images/upload/" \
        -H "Authorization: Ghost $jwt_token" \
        -F "file=@$image_path" \
        -F "purpose=image")
    
    local upload_url
    upload_url=$(echo "$response" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    if 'images' in data and len(data['images']) > 0:
        print(data['images'][0]['url'])
    else:
        print('', file=sys.stderr)
except:
    print('', file=sys.stderr)
")
    
    if [[ -n "$upload_url" ]]; then
        log "Image uploaded successfully: $upload_url"
        echo "$upload_url"
    else
        log "Failed to upload image: $image_path"
        echo ""
    fi
}

generate_tags() {
    local title="$1"
    local content="$2"
    
    python3 << EOF
import re
import json

title = """$title"""
content = """$content"""

text = (title + " " + content).lower()
text = re.sub(r'<[^>]+>', ' ', text)

potential_tags = [
    'photography', 'travel', 'architecture', 'nature', 'landscape', 
    'cityscape', 'street', 'portrait', 'art', 'culture', 'history',
    'adventure', 'explore', 'journey', 'wanderlust', 'scenic',
    'beautiful', 'inspiration', 'creative', 'artistic', 'visual'
]

found_tags = []
for tag in potential_tags:
    if tag in text and len(found_tags) < 4:
        found_tags.append(tag)

if len(found_tags) < 2:
    generic_tags = ['photography', 'visual', 'inspiration', 'art']
    for tag in generic_tags:
        if tag not in found_tags and len(found_tags) < 4:
            found_tags.append(tag)

print(json.dumps(found_tags[:4]))
EOF
}

create_photo_credit() {
    local photographer_name="$1"
    local photo_title="$2"
    local photo_url="$3"
    
    cat << EOF
<div class="photo-credit" style="margin-top: 2rem; padding: 1rem; border-left: 4px solid #e1e1e1; background: #f8f8f8;">
    <p style="margin: 0; font-size: 0.9rem; color: #666;">
        <strong>Photo Credit:</strong> 
        <em>$photo_title</em> by 
        <a href="$photo_url" target="_blank" rel="noopener">$photographer_name</a>
        on <a href="https://unsplash.com" target="_blank" rel="noopener">Unsplash</a>
    </p>
</div>
EOF
}

create_ghost_content() {
    local title="$1"
    local html_content="$2"
    local photographer_name="$3"
    local photo_title="$4"
    local photo_url="$5"
    local featured_image_url="$6"
    local content_type="$7"
    local status="$8"
    local author_id="$9"
    
    local photo_credit
    photo_credit=$(create_photo_credit "$photographer_name" "$photo_title" "$photo_url")
    
    local full_content="$html_content$photo_credit"
    
    local tags_json
    tags_json=$(generate_tags "$title" "$html_content")
    
    local current_time
    current_time=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
    
    python3 << EOF
import json

tags = json.loads('$tags_json')
tag_objects = [{"name": tag} for tag in tags]

content_data = {
    "title": """$title""",
    "html": """$full_content""",
    "status": "$status",
    "created_at": "$current_time",
    "updated_at": "$current_time"
}

if """$featured_image_url""".strip():
    content_data["feature_image"] = """$featured_image_url"""

if """$author_id""".strip():
    content_data["authors"] = [{"id": """$author_id"""}]

if tag_objects:
    content_data["tags"] = tag_objects

if "$content_type" == "post":
    result = {"posts": [content_data]}
else:
    result = {"pages": [content_data]}

print(json.dumps(result, ensure_ascii=False, indent=2))
EOF
}

post_to_ghost() {
    local json_payload="$1"
    local content_type="$2"
    local jwt_token="$3"
    
    local endpoint
    if [[ "$content_type" == "post" ]]; then
        endpoint="$GHOST_URL/ghost/api/admin/posts/?source=html"
    else
        endpoint="$GHOST_URL/ghost/api/admin/pages/?source=html"
    fi
    
    log "Posting to Ghost CMS: $endpoint"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "DRY RUN - Would post to: $endpoint"
        echo "Payload:"
        echo "$json_payload" | python3 -m json.tool
        echo "---"
        return 0
    fi
    
    local temp_file
    temp_file=$(mktemp)
    echo "$json_payload" > "$temp_file"
    
    local response_file=$(mktemp)
    
    http_code=$(curl -s -X POST \
        "$endpoint" \
        -H "Authorization: Ghost $jwt_token" \
        -H "Content-Type: application/json" \
        -d @"$temp_file" \
        -o "$response_file" \
        -w "%{http_code}")
    
    rm -f "$temp_file"
    
    local response_body
    response_body=$(cat "$response_file")
    rm -f "$response_file"
    
    if [[ "$http_code" == "201" ]]; then
        local content_url
        content_url=$(echo "$response_body" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    if 'posts' in data and len(data['posts']) > 0 and 'url' in data['posts'][0]:
        print(data['posts'][0]['url'])
    elif 'pages' in data and len(data['pages']) > 0 and 'url' in data['pages'][0]:
        print(data['pages'][0]['url'])
    else:
        print('')
except:
    print('')
")
        if [[ -n "$content_url" ]]; then
            echo "✓ Created successfully: $content_url"
        else
            echo "✓ Created successfully"
        fi
        return 0
    else
        echo "✗ Failed to create $content_type (HTTP $http_code)"
        echo "$response_body" | python3 -m json.tool 2>/dev/null || echo "$response_body"
        return 1
    fi
}

export_to_ghost() {
    local input_json="$1"
    
    echo "=== STEP 3: EXPORTING TO GHOST CMS ==="
    echo "Input JSON: $input_json"
    echo "Ghost URL: $GHOST_URL"
    echo "Content Type: $CONTENT_TYPE"
    echo "Status: $STATUS"
    [[ "$DRY_RUN" == "true" ]] && echo "Mode: DRY RUN"
    echo ""
    
    if [[ ! -f "$input_json" ]]; then
        error "Input JSON file not found: $input_json"
    fi
    
    local jwt_token
    jwt_token=$(generate_jwt_token "$GHOST_API_KEY")
    
    if [[ -z "$jwt_token" ]]; then
        error "Failed to generate JWT token"
    fi
    
    log "JWT token generated successfully"
    
    local total_items=$(jq '. | length' "$input_json")
    echo "Found $total_items items to process"
    echo ""
    
    local success_count=0
    local error_count=0
    
    for ((i = 0; i < total_items; i++)); do
        echo "Processing item $((i + 1))/$total_items..."
        
        local json_item=$(jq ".[$i]" "$input_json")
        
        local filename=$(echo "$json_item" | jq -r '.filename // ""')
        local photo_id=$(echo "$json_item" | jq -r '.id // ""')
        local description=$(echo "$json_item" | jq -r '.description // ""')
        local photographer_name=$(echo "$json_item" | jq -r '.photographer // ""')
        local photo_url=$(echo "$json_item" | jq -r '.photo_url // ""')
        local blog_title=$(echo "$json_item" | jq -r '.blog_title // ""')
        local blog_content=$(echo "$json_item" | jq -r '.blog_content // ""')
        
        if [[ -z "$blog_title" || -z "$blog_content" ]]; then
            echo "✗ Item $((i + 1)): Missing blog title or content"
            ((error_count++))
            continue
        fi
        
        if [[ "$blog_title" == "Error:"* ]]; then
            echo "✗ Item $((i + 1)): Content generation failed - $blog_title"
            ((error_count++))
            continue
        fi
        
        local json_dir
        json_dir=$(dirname "$input_json")
        local image_path="$json_dir/$filename"
        
        local featured_image_url=""
        if [[ -f "$image_path" ]]; then
            featured_image_url=$(upload_image "$image_path" "$jwt_token")
        else
            log "Warning: Image file not found: $image_path"
        fi
        
        local json_payload
        json_payload=$(create_ghost_content "$blog_title" "$blog_content" "$photographer_name" "$description" "$photo_url" "$featured_image_url" "$CONTENT_TYPE" "$STATUS" "$AUTHOR_ID")
        
        if post_to_ghost "$json_payload" "$CONTENT_TYPE" "$jwt_token"; then
            ((success_count++))
        else
            ((error_count++))
        fi
        
        sleep 1
    done
    
    echo ""
    echo "Ghost export complete!"
    echo "Items processed: $total_items"
    echo "Successful: $success_count"
    echo "Errors: $error_count"
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