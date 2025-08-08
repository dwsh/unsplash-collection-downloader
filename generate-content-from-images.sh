#!/bin/bash

SCRIPT_NAME=$(basename "$0")
CSV_FILE=""
OUTPUT_CSV=""
GEMINI_API_KEY=""
GEMINI_MODEL="gemini-1.5-flash"
RATE_LIMIT_DELAY=6  # Default delay in seconds (10 RPM = 6 seconds between requests)
TOKEN_WINDOW_START=0  # Track when current minute window started
TOKEN_COUNT=0  # Track tokens used in current minute
TEMPERATURE=0.7  # Default temperature for model creativity (0.0-1.0)

usage() {
    echo "Usage: $SCRIPT_NAME [OPTIONS]"
    echo ""
    echo "Generate blog post content from images using Gemini API analysis"
    echo "Output: JSON file with all original data plus generated blog_title and blog_content fields."
    echo ""
    echo "Options:"
    echo "  -f, --csv-file FILE    Input CSV file with image metadata (required)"
    echo "  -o, --output FILE      Output JSON file (default: input filename with .json extension)"
    echo "  -k, --api-key KEY      Gemini API key (optional, uses GEMINI_API_KEY env var)"
    echo "  -m, --model MODEL      Gemini model to use (default: gemini-1.5-flash)"
    echo "  -d, --delay SECONDS    Delay between API requests in seconds (default: auto)"
    echo "  -t, --temperature NUM  Model temperature 0.0-1.0 (default: 0.7)"
    echo "  --estimate-tokens TEXT Estimate tokens for given text (utility function)"
    echo "  -h, --help             Show this help message"
    echo ""
    echo "Available Models (Free Tier Limits - RPM/RPD/TPM):"
    echo "  gemini-1.5-flash       Fast and efficient (default, legacy model)"
    echo "  gemini-2.5-pro         5 RPM, 100 RPD, 250K TPM - Most capable"
    echo "  gemini-2.5-flash       10 RPM, 250 RPD, 250K TPM - Fast and efficient"  
    echo "  gemini-2.5-flash-lite  15 RPM, 1000 RPD, 250K TPM - Cost-efficient"
    echo "  gemini-2.0-flash       15 RPM, 200 RPD, 1M TPM - Next-gen features"
    echo "  gemini-1.5-pro         More capable but slower (legacy)"
    echo ""
    echo "Examples:"
    echo "  $SCRIPT_NAME -f 98913566_illustration/image_metadata.csv"
    echo "  $SCRIPT_NAME -f photos.csv -o photos_with_content.json"
    echo "  $SCRIPT_NAME -f photos.csv -k your-gemini-api-key -m gemini-2.5-pro"
    echo "  $SCRIPT_NAME -f photos.csv -m gemini-2.5-flash-lite -d 3"
    echo "  $SCRIPT_NAME -f photos.csv -t 0.9  # More creative output"
    echo "  $SCRIPT_NAME -f photos.csv -t 0.1  # More deterministic output"
    echo ""
    echo "Environment Variables:"
    echo "  GEMINI_API_KEY         Gemini API key (alternative to -k option)"
    echo ""
    echo "Rate Limiting:"
    echo "  The script automatically respects both request-per-minute (RPM) and"
    echo "  token-per-minute (TPM) limits for your selected model. It will pause"
    echo "  when approaching limits to prevent API errors. Be aware of daily limits!"
    echo ""
    echo "Token Calculation:"
    echo "  • Text: ~1 token per 4 characters (Gemini official guideline)"
    echo "  • Text: ~100 tokens per 60-80 English words"
    echo "  • Images: ~258 tokens per image"
    echo "  • Script uses conservative estimates (higher of char/word calculations)"
    echo ""
    echo "Temperature Control:"
    echo "  • 0.0: Highly deterministic, consistent outputs"
    echo "  • 0.7: Balanced creativity and consistency (default)"
    echo "  • 1.0: Maximum creativity and randomness"
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

get_rate_limit_delay() {
    local model="$1"
    
    case "$model" in
        "gemini-2.5-pro")
            echo 12  # 5 RPM = 12 seconds between requests
            ;;
        "gemini-2.5-flash")
            echo 6   # 10 RPM = 6 seconds between requests
            ;;
        "gemini-2.5-flash-lite")
            echo 4   # 15 RPM = 4 seconds between requests
            ;;
        "gemini-2.0-flash")
            echo 4   # 15 RPM = 4 seconds between requests
            ;;
        "gemini-1.5-flash"|"gemini-1.5-pro")
            echo 6   # Conservative estimate for legacy models
            ;;
        *)
            echo 6   # Default conservative delay
            ;;
    esac
}

get_tpm_limit() {
    local model="$1"
    
    case "$model" in
        "gemini-2.5-pro"|"gemini-2.5-flash"|"gemini-2.5-flash-lite")
            echo 250000  # 250K TPM
            ;;
        "gemini-2.0-flash"|"gemini-2.0-flash-lite")
            echo 1000000  # 1M TPM
            ;;
        "gemini-1.5-flash"|"gemini-1.5-pro")
            echo 200000   # Conservative estimate for legacy models
            ;;
        *)
            echo 200000   # Default conservative limit
            ;;
    esac
}

estimate_tokens() {
    local text="$1"
    local image_path="$2"
    
    # Token estimation based on Gemini API documentation:
    # - Text: ~1 token per 4 characters (official Gemini guideline)
    # - Alternative: ~100 tokens = 60-80 English words
    # - Image: ~258 tokens based on API documentation example
    
    # Count characters in text
    local char_count=${#text}
    local text_tokens=$((char_count / 4))
    
    # More accurate word-based estimation for English text (fallback)
    local word_count=$(echo "$text" | wc -w | tr -d ' ')
    local word_based_tokens=$((word_count * 100 / 70))  # ~70 words per 100 tokens average
    
    # Use the higher estimate for safety (conservative approach)
    if [[ $word_based_tokens -gt $text_tokens ]]; then
        text_tokens=$word_based_tokens
    fi
    
    # Image tokens (conservative estimate based on API examples)
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
    
    # Reset token count if we've moved to a new minute window
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
        # Reset for new window
        TOKEN_WINDOW_START=$(date +%s)
        TOKEN_COUNT=0
    fi
    
    # Update token count
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
    
    # Create a prompt for Gemini to analyze the image and generate blog content
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

    # Estimate tokens for this request with breakdown
    local text_char_count=${#prompt}
    local text_word_count=$(echo "$prompt" | wc -w | tr -d ' ')
    local estimated_tokens=$(estimate_tokens "$prompt" "$image_path")
    
    echo "  Token breakdown:" >&2
    echo "    Text: $text_char_count chars, $text_word_count words → ~$((estimated_tokens - 258)) tokens" >&2
    echo "    Image: ~258 tokens" >&2
    echo "    Total estimated: $estimated_tokens tokens" >&2
    
    # Check token limits before making API call
    check_token_limit "$estimated_tokens" "$GEMINI_MODEL"

    # Create temporary files
    local json_file="/tmp/gemini_request_$$.json"
    
    # Use Python to create JSON (handles large base64 strings better)
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
    
    # Call Gemini API to analyze the image
    local response=$(curl -s -X POST "https://generativelanguage.googleapis.com/v1beta/models/$GEMINI_MODEL:generateContent?key=$GEMINI_API_KEY" \
        -H "Content-Type: application/json" \
        -d @"$json_file")
    
    # Clean up temporary file
    rm -f "$json_file"
    
    if [[ -z "$response" ]]; then
        echo "Error: Empty response from Gemini API" >&2
        return 1
    fi
    
    # Check for API errors
    if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
        echo "Error: Gemini API error: $(echo "$response" | jq -r '.error.message')" >&2
        return 1
    fi
    
    # Check if response was truncated due to MAX_TOKENS
    local finish_reason=$(echo "$response" | jq -r '.candidates[0].finishReason' 2>/dev/null)
    if [[ "$finish_reason" == "MAX_TOKENS" ]]; then
        echo "Warning: Response truncated due to MAX_TOKENS limit" >&2
    fi
    
    # Extract the content from Gemini's response
    local gemini_text=$(echo "$response" | jq -r '.candidates[0].content.parts[0].text' 2>/dev/null)
    
    if [[ -z "$gemini_text" || "$gemini_text" == "null" ]]; then
        echo "Error: Could not extract content from Gemini response" >&2
        echo "Finish reason: $finish_reason" >&2
        echo "Response preview: $(echo "$response" | head -c 500)..." >&2
        return 1
    fi
    
    echo "$gemini_text"
}

process_csv() {
    local input_csv="$1"
    local output_json="$2"
    
    if [[ ! -f "$input_csv" ]]; then
        echo "Error: Input CSV file not found: $input_csv"
        exit 1
    fi
    
    echo "Processing CSV: $input_csv"
    echo "Output JSON: $output_json"
    
    # Create temporary file
    local temp_output="/tmp/generate_content_$$.json"
    
    # Initialize JSON array
    echo "[" > "$temp_output"
    
    # Process each row (skip header)
    local row_count=0
    local processed=0
    local failed=0
    
    # Parse CSV properly and convert to JSON structure
    local csv_items=$(python3 << EOF
import csv
import json
import sys

csv_data = []
with open('$input_csv', 'r', encoding='utf-8') as f:
    reader = csv.reader(f)
    header = next(reader)  # Read header
    
    for row in reader:
        if len(row) >= 16:  # Ensure we have all expected columns
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
    
    # Get image count from JSON data
    local image_count=$(echo "$csv_items" | jq '. | length')
    local total_time=$((image_count * RATE_LIMIT_DELAY))
    local hours=$((total_time / 3600))
    local minutes=$(((total_time % 3600) / 60))
    local seconds=$((total_time % 60))
    
    local tpm_limit=$(get_tpm_limit "$GEMINI_MODEL")
    
    echo "Images to process: $image_count"
    echo "Rate limit delay: ${RATE_LIMIT_DELAY}s per request"
    echo "Token limit: $(printf "%'d" $tpm_limit) TPM for $GEMINI_MODEL"
    echo "Temperature: $TEMPERATURE (creativity level)"
    if [[ $hours -gt 0 ]]; then
        echo "Estimated time: ${hours}h ${minutes}m ${seconds}s"
    elif [[ $minutes -gt 0 ]]; then
        echo "Estimated time: ${minutes}m ${seconds}s"
    else
        echo "Estimated time: ${seconds}s"
    fi
    echo ""
    
    # Initialize token tracking
    TOKEN_WINDOW_START=$(date +%s)
    TOKEN_COUNT=0
    
    # Process each item
    local first_item=true
    for ((i = 0; i < image_count; i++)); do
        ((row_count++))
        
        echo "Processing row $row_count..."
        
        # Extract item data from JSON
        local item_data=$(echo "$csv_items" | jq -r ".[$i]")
        local filename=$(echo "$item_data" | jq -r '.filename')
        local description=$(echo "$item_data" | jq -r '.description')
        local photographer=$(echo "$item_data" | jq -r '.photographer')
        
        # Get the directory from the CSV path
        local csv_dir=$(dirname "$input_csv")
        local image_path="$csv_dir/$filename"
        
        echo "  Image: $filename"
        echo "  Description: $description"
        echo "  Photographer: $photographer"
        
        # Analyze image with Gemini
        local gemini_response=$(analyze_image_with_gemini "$image_path" "$description" "$photographer")
        
        if [[ $? -eq 0 && -n "$gemini_response" ]]; then
            # Remove markdown code blocks if present
            local clean_response=$(echo "$gemini_response" | sed 's/^```json//' | sed 's/```$//')
            
            # Parse Gemini's JSON response
            local blog_title=$(echo "$clean_response" | jq -r '.title // "Untitled"' 2>/dev/null)
            local blog_content=$(echo "$clean_response" | jq -r '.content // ""' 2>/dev/null)
            
            if [[ -n "$blog_title" && -n "$blog_content" && "$blog_title" != "null" && "$blog_content" != "null" ]]; then
                # Create complete JSON item with original data plus generated content
                local json_item=$(echo "$item_data" | jq --arg title "$blog_title" --arg content "$blog_content" '. + {blog_title: $title, blog_content: $content}')
                
                # Add comma if not first item
                if [[ "$first_item" != "true" ]]; then
                    echo "," >> "$temp_output"
                fi
                first_item=false
                
                # Write JSON item to output
                echo "$json_item" >> "$temp_output"
                
                echo "  ✓ Generated content: $blog_title"
                ((processed++))
            else
                echo "  ✗ Failed to parse Gemini response"
                
                # Add error item to JSON
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
            
            # Add error item to JSON
            local error_item=$(echo "$item_data" | jq '. + {blog_title: "Error: Analysis failed", blog_content: ""}')
            
            if [[ "$first_item" != "true" ]]; then
                echo "," >> "$temp_output"
            fi
            first_item=false
            
            echo "$error_item" >> "$temp_output"
            ((failed++))
        fi
        
        echo ""
        
        # Rate limiting based on model's free tier limits
        if [[ $row_count -lt $image_count ]]; then
            echo "  Waiting ${RATE_LIMIT_DELAY}s to respect API rate limits..."
            sleep "$RATE_LIMIT_DELAY"
        fi
    done
    
    # Close JSON array
    echo "]" >> "$temp_output"
    
    # Move temporary file to final output
    mv "$temp_output" "$output_json"
    
    echo "Processing complete!"
    echo "Processed: $processed images"
    echo "Failed: $failed images"
    echo "Output saved to: $output_json"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--csv-file)
            CSV_FILE="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_JSON="$2"
            shift 2
            ;;
        -k|--api-key)
            GEMINI_API_KEY="$2"
            shift 2
            ;;
        -m|--model)
            GEMINI_MODEL="$2"
            shift 2
            ;;
        -d|--delay)
            RATE_LIMIT_DELAY="$2"
            shift 2
            ;;
        -t|--temperature)
            TEMPERATURE="$2"
            shift 2
            ;;
        --estimate-tokens)
            # Utility function to estimate tokens for given text
            echo "Token estimation for: \"$2\""
            echo "Characters: ${#2}"
            echo "Words: $(echo "$2" | wc -w | tr -d ' ')"
            echo "Estimated tokens: $(estimate_tokens "$2" "")"
            exit 0
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

# Validate required parameters
if [[ -z "$CSV_FILE" ]]; then
    echo "Error: CSV file is required. Use -f or --csv-file"
    usage
    exit 1
fi

# Validate Gemini model
case "$GEMINI_MODEL" in
    "gemini-2.5-flash"|"gemini-2.5-pro"|"gemini-2.5-flash-lite"|"gemini-2.0-flash"|"gemini-1.5-flash"|"gemini-1.5-pro")
        ;;
    *)
        echo "Error: Invalid Gemini model '$GEMINI_MODEL'"
        echo "Supported models: gemini-2.5-flash, gemini-2.5-pro, gemini-2.5-flash-lite, gemini-2.0-flash, gemini-1.5-flash, gemini-1.5-pro"
        exit 1
        ;;
esac

# Validate temperature parameter  
if ! [[ "$TEMPERATURE" =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]]; then
    echo "Error: Temperature must be a number between 0.0 and 1.0"
    echo "Current value: $TEMPERATURE"
    echo "Examples: 0.0, 0.7, 1.0"
    exit 1
fi

# Set intelligent rate limiting delay if not specified
if [[ "$RATE_LIMIT_DELAY" -eq 6 ]]; then
    RATE_LIMIT_DELAY=$(get_rate_limit_delay "$GEMINI_MODEL")
    echo "Using model-specific rate limit: ${RATE_LIMIT_DELAY}s delay for $GEMINI_MODEL"
fi

# Set default output file if not specified
if [[ -z "$OUTPUT_JSON" ]]; then
    # Change extension from .csv to .json
    local csv_dir=$(dirname "$CSV_FILE")
    local csv_base=$(basename "$CSV_FILE" .csv)
    OUTPUT_JSON="$csv_dir/${csv_base}.json"
fi

# Check if Gemini API key is available (from command line or environment)
if [[ -z "$GEMINI_API_KEY" ]]; then
    echo "Error: Gemini API key is required."
    echo "Set GEMINI_API_KEY environment variable or use -k option"
    echo "Get your API key from: https://makersuite.google.com/app/apikey"
    exit 1
fi

# Process the CSV file
process_csv "$CSV_FILE" "$OUTPUT_JSON"
