#!/bin/bash

# Exit on error, undefined variables, and pipe failures
set -euo pipefail

# Default configuration (can be overridden by CLI args or env vars)
KONNECT_ADDR=${KONNECT_ADDR:-"https://us.api.konghq.com"}
KONNECT_CONTROL_PLANE=${KONNECT_CONTROL_PLANE:-"default"}
KONNECT_TOKEN=${KONNECT_TOKEN:-""}
TYK_DASHBOARD_URL=${TYK_DASHBOARD_URL:-"http://tyk-dashboard.localhost:3000"}
TYK_AUTH_TOKEN=${TYK_AUTH_TOKEN:-""}
DATA_DIR=${DATA_DIR:-"./json-data"}
KONG_DUMP_FILE="$DATA_DIR/kong-dump.json"
KONG_OAS_FILE="$DATA_DIR/kong-oas.json"

# Print usage information
usage() {
    cat << EOF
Usage: $(basename "$0") [options]

Migrate Kong configuration to Tyk

Options:
    -h, --help                      Show this help message
    --konnect-addr URL              Kong Connect address (default: $KONNECT_ADDR)
    --konnect-control-plane NAME    Kong Control Plane name (default: $KONNECT_CONTROL_PLANE)
    --konnect-token TOKEN           Kong Connect token (required if not set in env)
    --tyk-url URL                   Tyk Dashboard URL (default: $TYK_DASHBOARD_URL)
    --tyk-token TOKEN               Tyk Auth token (required if not set in env)
    --data-dir PATH                 Directory for JSON data (default: $DATA_DIR)

Environment variables:
    KONNECT_ADDR
    KONNECT_CONTROL_PLANE
    KONNECT_TOKEN
    TYK_DASHBOARD_URL
    TYK_AUTH_TOKEN
    DATA_DIR

EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                exit 0
                ;;
            --konnect-addr)
                KONNECT_ADDR="$2"
                shift 2
                ;;
            --konnect-control-plane)
                KONNECT_CONTROL_PLANE="$2"
                shift 2
                ;;
            --konnect-token)
                KONNECT_TOKEN="$2"
                shift 2
                ;;
            --tyk-url)
                TYK_DASHBOARD_URL="$2"
                shift 2
                ;;
            --tyk-token)
                TYK_AUTH_TOKEN="$2"
                shift 2
                ;;
            --data-dir)
                DATA_DIR="$2"
                KONG_DUMP_FILE="$DATA_DIR/kong-dump.json"
                KONG_OAS_FILE="$DATA_DIR/kong-oas.json"
                shift 2
                ;;
            *)
                echo "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

# Validate required parameters
validate_params() {
    local missing_params=()

    if [[ -z "$KONNECT_TOKEN" ]]; then
        missing_params+=("Kong Connect token (--konnect-token or KONNECT_TOKEN)")
    fi
    if [[ -z "$TYK_AUTH_TOKEN" ]]; then
        missing_params+=("Tyk Auth token (--tyk-token or TYK_AUTH_TOKEN)")
    fi

    if [[ ${#missing_params[@]} -ne 0 ]]; then
        echo "Error: Missing required parameters:"
        printf '%s\n' "${missing_params[@]}"
        echo
        usage
        exit 1
    fi
}

# Prepare data directory
prepare_data_dir() {
    log_info "Preparing data directory: $DATA_DIR"
    rm -rf "$DATA_DIR"
    mkdir -p "$DATA_DIR"
}

# Log functions
log_info() {
    echo "[INFO] $1"
}

log_error() {
    echo "[ERROR] $1" >&2
}

# Error handler
handle_error() {
    log_error "An error occurred on line $1"
    exit 1
}

trap 'handle_error $LINENO' ERR

# Function to export Kong configuration
export_kong_config() {
    log_info "Exporting Kong configuration..."
    deck \
        --konnect-addr "$KONNECT_ADDR" \
        --konnect-control-plane-name "$KONNECT_CONTROL_PLANE" \
        --konnect-token "$KONNECT_TOKEN" \
        --format json \
        -o "$KONG_DUMP_FILE" \
        gateway dump --yes
}

# Function to transform Kong config to OpenAPI specs
transform_to_oas() {
    log_info "Transforming Kong configuration to OpenAPI specs..."
    jq -c '[
        .services[] | {
            "info": {
                "title": .name,
                "version": "1.0.0"
            },
            "openapi": "3.0.3",
            "paths": {},
            "x-tyk-api-gateway": {
                "info": {
                    "name": .name,
                    "state": {
                        "active": true,
                        "internal": false
                    }
                },
                "server": {
                    "listenPath": {
                        "strip": true,
                        "value": .routes[0].paths[0]
                    }
                },
                "upstream": {
                    "url": (.protocol + "://" + .host + .path)      
                }
            }
        }
    ]' "$KONG_DUMP_FILE" > "$KONG_OAS_FILE"
}

# Function to split OpenAPI specs into individual files
split_oas_files() {
    log_info "Splitting OpenAPI specs into individual files..."
    jq -r '.[].info.title' "$KONG_OAS_FILE" | while read -r title; do
        jq ".[] | select(.info.title == \"$title\")" "$KONG_OAS_FILE" > "$DATA_DIR/oas-${title}.json"
    done
}

# Function to import specs into Tyk
import_to_tyk() {
    log_info "Importing OpenAPI specs into Tyk..."
    find "$DATA_DIR" -name "oas-*.json" -print0 | while IFS= read -r -d '' file; do
        log_info "Importing $file..."
        response=$(curl -s -X POST "$TYK_DASHBOARD_URL/api/apis/oas" \
            -H "Authorization: $TYK_AUTH_TOKEN" \
            -H "Content-Type: application/json" \
            --data @"$file")
        
        if echo "$response" | jq -e '.Status == "OK"' >/dev/null 2>&1; then
            log_info "Successfully imported $file"
        else
            log_error "Failed to import $file. Response: $response"
            exit 1
        fi
    done
}

# Main execution
main() {
    parse_args "$@"
    validate_params
    prepare_data_dir
    
    log_info "Starting Kong to Tyk migration..."
    
    export_kong_config
    transform_to_oas
    split_oas_files
    import_to_tyk
    
    log_info "Migration completed successfully"
}

# Execute main function with all command line arguments
main "$@"
