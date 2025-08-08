# Unsplash Collection Downloader & AI Content Generator

A complete toolkit for downloading images from Unsplash collections and generating AI-powered blog content from them.

## Features

### Image Collection (`download_unsplash.sh`)
- 📥 Download images from any public Unsplash collection
- 📊 Export comprehensive metadata to CSV format
- 🔄 Automatic pagination support (downloads all photos, not limited to 30)
- 📁 Organized output with collection-based directory structure
- ⚡ Rate limiting and error handling
- 🔧 Configurable download count and output directories

### AI Content Generation (`generate-content-from-images.sh`)
- 🤖 Generate blog post titles and HTML content using Google's Gemini API
- 🎨 Multiple Gemini models with intelligent rate limiting (2.5-Pro, 2.5-Flash, etc.)
- 📝 Temperature control for content creativity (0.0-1.0)
- 🔢 Automatic token estimation and TPM/RPM limit handling
- 📄 JSON output format for robust data handling
- 🚀 Batch processing with comprehensive error handling

### Ghost CMS Integration (`export-to-ghost.sh`)
- 👻 Export generated content directly to Ghost CMS as posts or pages
- 🖼️ Automatic featured image upload and assignment
- 📸 Photo credit attribution with photographer links
- 🏷️ Intelligent tag generation (max 4 tags)
- 🔐 JWT authentication with Ghost Admin API
- 🎛️ Draft/published status control

## Prerequisites

### Required Tools
- `curl` - for API requests and image downloads
- `jq` - for JSON parsing
- `python3` - for advanced data processing
- `openssl` - for JWT token generation
- `base64` - for encoding operations

### API Keys
- **Unsplash API access key** - for image downloads
- **Google Gemini API key** - for content generation
- **Ghost Admin API key** - for CMS integration (optional)

### Installing Dependencies

**macOS:**
```bash
brew install curl jq python3 openssl
```

**Ubuntu/Debian:**
```bash
sudo apt-get install curl jq python3 openssl-dev
```

## Setup

### 1. Get API Keys

**Unsplash API:**
- Go to https://unsplash.com/developers
- Sign in or create an account
- Click "New Application"
- Fill out the application form
- Copy your **Access Key** (not the secret key)

**Google Gemini API:**
- Go to https://makersuite.google.com/app/apikey
- Sign in with your Google account
- Create a new API key
- Copy the generated key

**Ghost CMS API (optional):**
- Go to your Ghost Admin panel: `https://yourblog.com/ghost/`
- Navigate to Settings → Integrations
- Create a "Custom Integration"
- Copy the Admin API Key in `id:secret` format

### 2. Make Scripts Executable
```bash
chmod +x download_unsplash.sh generate-content-from-images.sh export-to-ghost.sh
```

### 3. Set Environment Variables (Optional)
```bash
export GEMINI_API_KEY="your_gemini_api_key_here"
```

## Usage

### Complete Workflow

```bash
# Step 1: Download images from Unsplash collection
./download_unsplash.sh -k YOUR_UNSPLASH_KEY -i COLLECTION_ID

# Step 2: Generate AI content from images
./generate-content-from-images.sh -f collection_folder/image_metadata.csv -k YOUR_GEMINI_KEY

# Step 3: Export to Ghost CMS (optional)
./export-to-ghost.sh -f collection_folder/image_metadata.json -k "ghost_id:secret" -u "https://yourblog.com"
```

### Script-Specific Usage

#### 1. Download Images (`download_unsplash.sh`)

**Basic:**
```bash
./download_unsplash.sh -k YOUR_ACCESS_KEY -i COLLECTION_ID
```

**Options:**
```
-k, --api-key KEY      Unsplash API access key (required)
-i, --collection-id ID Collection ID to download from (required)
-c, --count NUMBER     Number of images to download (default: 10)
-d, --dir DIRECTORY    Download directory (default: [collection_id]_[collection_title])
-o, --output CSV_FILE  CSV output filename (default: image_metadata.csv in download dir)
-h, --help             Show help message
```

**Examples:**
```bash
# Download 20 images from a collection
./download_unsplash.sh -k YOUR_ACCESS_KEY -i 98913566 -c 20

# Download all images to a custom directory
./download_unsplash.sh -k YOUR_ACCESS_KEY -i 98913566 -c 1000 -d my_photos
```

#### 2. Generate AI Content (`generate-content-from-images.sh`)

**Basic:**
```bash
./generate-content-from-images.sh -f image_metadata.csv -k YOUR_GEMINI_KEY
```

**Options:**
```
-f, --csv-file FILE    Input CSV file with image metadata (required)
-o, --output FILE      Output JSON file (default: input filename with .json extension)
-k, --api-key KEY      Gemini API key (optional if GEMINI_API_KEY env var set)
-m, --model MODEL      Gemini model (default: gemini-1.5-flash)
-t, --temperature NUM  Model temperature 0.0-1.0 (default: 0.7)
-d, --delay SECONDS    Custom delay between requests (default: auto)
```

**Available Models:**
- `gemini-2.5-pro` - Most capable (5 RPM, 250K TPM)
- `gemini-2.5-flash` - Fast and efficient (10 RPM, 250K TPM)
- `gemini-2.5-flash-lite` - Cost-efficient (15 RPM, 250K TPM)
- `gemini-2.0-flash` - Next-gen features (15 RPM, 1M TPM)

**Examples:**
```bash
# Generate with default settings
./generate-content-from-images.sh -f photos.csv

# Use creative model with high temperature
./generate-content-from-images.sh -f photos.csv -m gemini-2.5-pro -t 0.9

# More deterministic output
./generate-content-from-images.sh -f photos.csv -t 0.1
```

#### 3. Export to Ghost CMS (`export-to-ghost.sh`)

**Basic:**
```bash
./export-to-ghost.sh -f image_metadata.json -k "id:secret" -u "https://yourblog.com"
```

**Options:**
```
-f, --file JSON_FILE   Input JSON file path (required)
-k, --api-key API_KEY  Ghost Admin API key in id:secret format (required)
-u, --url GHOST_URL    Ghost site URL (required)
-t, --type TYPE        Content type: 'post' or 'page' (default: post)
-s, --status STATUS    Publication status: 'draft' or 'published' (default: draft)
-a, --author AUTHOR_ID Author ID (optional)
-d, --dry-run          Preview without posting
```

**Examples:**
```bash
# Export as draft posts
./export-to-ghost.sh -f content.json -k "id:secret" -u "https://yourblog.com"

# Export as published pages
./export-to-ghost.sh -f content.json -k "id:secret" -u "https://yourblog.com" -t page -s published

# Dry run to preview
./export-to-ghost.sh -f content.json -k "id:secret" -u "https://yourblog.com" --dry-run
```

## Finding Collection IDs

Collection IDs can be found in Unsplash collection URLs:
- URL: `https://unsplash.com/collections/98913566/illustration`
- Collection ID: `98913566`

## Output Structure

The toolkit creates organized directories with multiple data formats:

```
98913566_illustration/
├── image_metadata.csv        # Original Unsplash metadata
├── image_metadata.json       # Enhanced with AI-generated content
├── lhsfeT9WZ9M.jpg          # Downloaded images
├── hYCWh6Cakxk.jpg
└── I-Jkpdx0r4U.jpg
```

### Data Formats

#### CSV Metadata (from `download_unsplash.sh`)
Original Unsplash data with the following fields:
- `filename` - Downloaded image filename
- `id` - Unsplash photo ID  
- `description` - Photo description
- `alt_description` - Alternative description
- `photographer` - Photographer's name
- `photographer_username` - Photographer's username
- `width`, `height` - Image dimensions
- `likes`, `downloads` - Engagement metrics
- `created_at`, `updated_at` - Timestamps
- `color` - Dominant color
- `blur_hash` - BlurHash for placeholder
- `download_url` - Direct download URL
- `photo_url` - Unsplash photo page URL

#### JSON Output (from `generate-content-from-images.sh`)
Enhanced data structure with all original fields plus:
- `blog_title` - AI-generated blog post title
- `blog_content` - AI-generated HTML content (4-12 paragraphs)

**Example JSON structure:**
```json
[
  {
    "filename": "lhsfeT9WZ9M.jpg",
    "id": "lhsfeT9WZ9M",
    "description": "The Blind Girl, 1856. Artist: John Everett Millais",
    "photographer": "Birmingham Museums Trust",
    "photo_url": "https://unsplash.com/photos/...",
    "blog_title": "The Unseen Symphony: How We Truly Experience Life",
    "blog_content": "<p>In a world often dominated by what we see...</p><p>...</p>"
  }
]
```

## Features in Detail

### Image Collection (`download_unsplash.sh`)
- **Pagination Support**: Automatically handles Unsplash's 30-photo-per-request limit
- **Rate Limiting**: 1-second delays between API requests to respect limits
- **Error Handling**: Validates API keys, checks for empty/private collections
- **CSV Safety**: Properly escapes special characters in CSV fields

### AI Content Generation (`generate-content-from-images.sh`)
- **Multiple Models**: Support for latest Gemini 2.5 models with different capabilities
- **Intelligent Rate Limiting**: Respects both RPM (requests per minute) and TPM (tokens per minute) limits
- **Token Estimation**: Accurate token counting for text (~1 token per 4 characters) and images (~258 tokens)
- **Temperature Control**: Adjust creativity from deterministic (0.0) to highly creative (1.0)
- **Robust Error Handling**: Handles API errors, token limits, and parsing failures gracefully
- **JSON Output**: Eliminates CSV parsing issues with structured JSON format

### Ghost CMS Integration (`export-to-ghost.sh`)
- **JWT Authentication**: Secure authentication with Ghost Admin API
- **Image Upload**: Automatically uploads and assigns featured images
- **Photo Attribution**: Generates proper photo credits with photographer links
- **Tag Generation**: Intelligently creates up to 4 relevant tags based on content
- **Flexible Publishing**: Choose between posts/pages and draft/published status
- **Dry Run Mode**: Preview what would be created before actually posting

## Rate Limits & Costs

### Unsplash API
- **Demo/Development**: 50 requests per hour
- **Production**: 5,000 requests per hour

### Google Gemini API (Free Tier)
| Model | Requests/Min | Requests/Day | Tokens/Min |
|-------|--------------|--------------|------------|
| gemini-2.5-pro | 5 | 100 | 250K |
| gemini-2.5-flash | 10 | 250 | 250K |
| gemini-2.5-flash-lite | 15 | 1000 | 250K |
| gemini-2.0-flash | 15 | 200 | 1M |

*The scripts automatically handle these limits with appropriate delays*

### Ghost CMS API
- No specific rate limits documented
- Script includes 1-second delays between requests to be respectful

## Limitations

### General
- Requires internet connection
- Only works with public Unsplash collections
- Downloads full-resolution images (bandwidth intensive)

### AI Content Generation
- Subject to Gemini API rate limits and daily quotas
- Content quality depends on image context and descriptions
- Requires sufficient Gemini API credits for large collections

### Ghost CMS Export  
- Requires Ghost Admin API access (custom integration)
- Featured images must be accessible from local file paths
- Ghost site must be accessible from where script runs

## License

This project is open source and available under the MIT License.

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.