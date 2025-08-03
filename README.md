# Unsplash Collection Downloader

A bash script to download images from Unsplash collections with metadata export to CSV.

## Features

- 📥 Download images from any public Unsplash collection
- 📊 Export comprehensive metadata to CSV format
- 🔄 Automatic pagination support (downloads all photos, not limited to 30)
- 📁 Organized output with collection-based directory structure
- ⚡ Rate limiting and error handling
- 🔧 Configurable download count and output directories

## Prerequisites

- `curl` - for API requests and image downloads
- `jq` - for JSON parsing
- Unsplash API access key

### Installing Dependencies

**macOS:**
```bash
brew install curl jq
```

**Ubuntu/Debian:**
```bash
sudo apt-get install curl jq
```

## Setup

1. Get your Unsplash API access key:
   - Go to https://unsplash.com/developers
   - Sign in or create an account
   - Click "New Application"
   - Fill out the application form
   - Copy your **Access Key** (not the secret key)

2. Make the script executable:
   ```bash
   chmod +x download_unsplash.sh
   ```

## Usage

### Basic Usage

```bash
./download_unsplash.sh -k YOUR_ACCESS_KEY -i COLLECTION_ID
```

### Options

```
-k, --api-key KEY      Unsplash API access key (required)
-i, --collection-id ID Collection ID to download from (required)
-c, --count NUMBER     Number of images to download (default: 10)
-d, --dir DIRECTORY    Download directory (default: [collection_id]_[collection_title])
-o, --output CSV_FILE  CSV output filename (default: image_metadata.csv in download dir)
-h, --help             Show help message
```

### Examples

Download 20 images from a collection:
```bash
./download_unsplash.sh -k YOUR_ACCESS_KEY -i 98913566 -c 20
```

Download all images to a custom directory:
```bash
./download_unsplash.sh -k YOUR_ACCESS_KEY -i 98913566 -c 1000 -d my_photos
```

Download with custom CSV filename:
```bash
./download_unsplash.sh -k YOUR_ACCESS_KEY -i 98913566 -o custom_metadata.csv
```

## Finding Collection IDs

Collection IDs can be found in Unsplash collection URLs:
- URL: `https://unsplash.com/collections/98913566/illustration`
- Collection ID: `98913566`

## Output Structure

By default, the script creates organized directories:

```
98913566_illustration/
├── image_metadata.csv
├── lhsfeT9WZ9M.jpg
├── hYCWh6Cakxk.jpg
└── I-Jkpdx0r4U.jpg
```

### CSV Metadata Fields

The exported CSV contains the following fields for each image:
- `filename` - Downloaded image filename
- `id` - Unsplash photo ID
- `description` - Photo description
- `alt_description` - Alternative description
- `photographer` - Photographer's name
- `photographer_username` - Photographer's username
- `width` - Image width in pixels
- `height` - Image height in pixels
- `likes` - Number of likes
- `downloads` - Download count
- `created_at` - Creation timestamp
- `updated_at` - Last update timestamp
- `color` - Dominant color
- `blur_hash` - BlurHash for placeholder
- `download_url` - Direct download URL
- `photo_url` - Unsplash photo page URL

## Features in Detail

### Pagination Support
The script automatically handles Unsplash's 30-photo-per-request limit by making multiple API calls to download entire collections.

### Rate Limiting
Includes 1-second delays between API requests to respect Unsplash's rate limits.

### Error Handling
- Validates API keys and collection IDs
- Checks for empty or private collections
- Handles network errors gracefully
- Reports failed downloads

### CSV Safety
Properly escapes special characters in CSV fields to prevent parsing issues.

## Limitations

- Only works with public collections
- Requires internet connection
- Subject to Unsplash API rate limits
- Downloads full-resolution images (can be bandwidth intensive)

## License

This project is open source and available under the MIT License.

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.