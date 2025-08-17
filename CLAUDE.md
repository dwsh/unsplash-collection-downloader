# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Core Architecture

This is a complete **Unsplash to Ghost CMS pipeline** consisting of three main bash scripts that work together:

1. **download_unsplash.sh** - Downloads images from Unsplash collections with metadata export
2. **generate-content-from-images.sh** - Uses Google Gemini AI to generate blog content from images
3. **export-to-ghost.sh** - Uploads images and creates posts/pages in Ghost CMS
4. **unsplash-to-ghost-pipeline.sh** - Complete pipeline script that orchestrates all three steps

## Data Flow

```
Unsplash Collection → CSV metadata → JSON with AI content → Ghost CMS posts/pages
```

### File Structure Pattern
```
[collection_id]_[collection_name]/
├── image_metadata.csv          # Original Unsplash metadata
├── image_metadata.json         # Enhanced with AI-generated content
├── [photo_id].jpg             # Downloaded images
└── [photo_id].jpg
```

### Key Data Transformations
- **CSV → JSON**: Scripts convert CSV to JSON format for easier manipulation
- **Metadata Enhancement**: AI adds `blog_title` and `blog_content` fields to original Unsplash data
- **Ghost Integration**: JSON data is transformed into Ghost CMS API format with featured images

## Common Commands

### Individual Script Usage
```bash
# Download images from collection
./download_unsplash.sh -k UNSPLASH_KEY -i 12345678 -c 20

# Generate content from existing CSV
./generate-content-from-images.sh -f collection_folder/image_metadata.csv -k GEMINI_KEY

# Export to Ghost CMS
./export-to-ghost.sh -f collection_folder/image_metadata.json -k "ghost_id:secret" -u "https://yourblog.com"
```

### Complete Pipeline
```bash
# Full pipeline
./unsplash-to-ghost-pipeline.sh -k UNSPLASH_KEY -i 12345678 -g GEMINI_KEY -G "ghost_id:secret" -u "https://yourblog.com"

# Skip certain steps
./unsplash-to-ghost-pipeline.sh --skip-download -d existing_folder -g GEMINI_KEY -G "ghost_id:secret" -u "https://yourblog.com"
./unsplash-to-ghost-pipeline.sh -k UNSPLASH_KEY -i 12345678 -g GEMINI_KEY --skip-ghost
```

### Testing and Development
```bash
# Make scripts executable
chmod +x *.sh

# Dry run (preview what would be created)
./export-to-ghost.sh -f collection.json -k "id:secret" -u "https://yourblog.com" --dry-run

# Check dependencies
./download_unsplash.sh --help  # Shows required dependencies
```

## API Configuration

### Required API Keys
- **UNSPLASH_API_KEY**: From https://unsplash.com/developers
- **GEMINI_API_KEY**: From https://makersuite.google.com/app/apikey (can be set as env var)
- **GHOST_API_KEY**: From Ghost Admin → Integrations (format: `id:secret`)

### Rate Limiting
Scripts automatically handle API rate limits:
- **Unsplash**: 1-second delays between requests
- **Gemini**: Model-specific delays (4-12 seconds based on RPM limits)
- **Ghost**: 1-second delays between uploads

## Key Implementation Details

### CSV Handling
- Uses proper CSV escaping for special characters
- Headers: `filename,id,description,alt_description,photographer,photographer_username,width,height,likes,downloads,created_at,updated_at,color,blur_hash,download_url,photo_url`

### Gemini Integration
- Supports multiple models (gemini-2.5-pro, gemini-2.5-flash, etc.)
- Token estimation for both text and images
- Temperature control for creativity (0.0-1.0)
- Automatic TPM (tokens per minute) tracking

### Ghost CMS Features
- JWT authentication with Admin API
- Automatic featured image upload
- Photo credit attribution
- Tag generation from content analysis
- Support for both posts and pages

### Error Handling
- Comprehensive validation of API keys and collection IDs
- Graceful handling of failed downloads/uploads
- Detailed logging and progress reporting
- Rollback-safe operations (temp files, atomic moves)

## Dependencies

Required system tools:
- `curl` - API requests and downloads
- `jq` - JSON processing
- `python3` - Data manipulation and JWT generation
- `openssl` - JWT token creation
- `base64` - Encoding operations

All scripts include dependency checking and installation instructions.