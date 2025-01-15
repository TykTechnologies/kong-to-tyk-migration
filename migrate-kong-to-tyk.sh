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

# Check if API exists in Tyk
api_exists_in_tyk() {
    local listen_path="$1"
    local response
    response=$(curl -s -X GET "$TYK_DASHBOARD_URL/api/apis?p=-1" \
        -H "Authorization: $TYK_AUTH_TOKEN")
    echo "$response" | jq -e ".apis[] | select(.api_definition.proxy.listen_path == \"$listen_path\")" >/dev/null 2>&1
}

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
    local titles
    titles=$(jq -r '.[].info.title' "$KONG_OAS_FILE")
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Failed to extract API titles from OpenAPI specs"
        exit 1
    fi

    while IFS= read -r title; do
        [[ -z "$title" ]] && continue
        jq ".[] | select(.info.title == \"$title\")" "$KONG_OAS_FILE" > "$DATA_DIR/oas-${title}.json"
        if [[ $? -ne 0 ]]; then
            log_error "Failed to extract OpenAPI spec for $title"
            exit 1
        fi
    done <<< "$titles"
}

# Function to import a single spec into Tyk
import_single_spec() {
    local file="$1"
    local listen_path
    listen_path=$(jq -r '."x-tyk-api-gateway".server.listenPath.value' "$file")
    if [[ $? -ne 0 ]]; then
        log_error "Failed to extract listen path from $file"
        return 1
    fi

    if api_exists_in_tyk "$listen_path"; then
        log_info "API with listen path $listen_path already exists in Tyk. Skipping import for $file."
        return 0
    fi

    log_info "Importing $file..."
    local response
    response=$(curl -s -X POST "$TYK_DASHBOARD_URL/api/apis/oas" \
        -H "Authorization: $TYK_AUTH_TOKEN" \
        -H "Content-Type: application/json" \
        --data @"$file")
    local curl_exit_status=$?

    if [[ $curl_exit_status -ne 0 ]]; then
        log_error "Failed to connect to Tyk Dashboard. curl exit status: $curl_exit_status"
        log_error "Ensure the Tyk Dashboard is running and reachable at $TYK_DASHBOARD_URL"
        exit 1  # Exit immediately on curl failure
    fi

    if echo "$response" | jq -e '.Status == "OK"' >/dev/null 2>&1; then
        log_info "Successfully imported $file"
        return 0
    else
        log_error "Failed to import $file. Response: $response"
        return 1
    fi
}

# Function to import specs into Tyk
import_to_tyk() {
    log_info "Importing OpenAPI specs into Tyk..."
    local failed_imports=0
    
    # Use while loop with find to process files
    while IFS= read -r -d '' file; do
        if ! import_single_spec "$file"; then
            ((failed_imports++))
        fi
    done < <(find "$DATA_DIR" -name "oas-*.json" -print0)

    if [[ $failed_imports -gt 0 ]]; then
        log_error "Failed to import $failed_imports API(s)"
        return 1
    fi
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