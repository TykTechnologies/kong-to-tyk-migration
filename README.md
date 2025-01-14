# Kong to Tyk Migration Script

This script automates the migration of Kong configuration to Tyk by exporting Kong configuration, transforming it into OpenAPI specifications, and importing it into Tyk.

## Features

- Exports Kong configuration via `deck`.
- Transforms Kong configuration to OpenAPI specifications using `jq`.
- Splits the OpenAPI specifications into individual JSON files.
- Imports the specifications into the Tyk Dashboard.
- Uses a dedicated directory for JSON data, which is wiped before each run.

## Disclaimer

This script is provided as-is, without warranty of any kind. It is intended as an example to assist in migrating API definitions from Kong to Tyk.

Before running the script, ensure you have proper backups of your data.
Test the script in a non-production environment first.
Adjustments may be required to meet specific use cases or configurations.
Tyk assumes no liability for any issues arising from the use of this script. Use it at your own risk.

## Prerequisites

1. **Dependencies**:
   - `deck` (Kong Declarative Configuration Tool)
   - `jq` (Command-line JSON processor)
   - `curl` (For API communication)

2. **Access Credentials**:
   - Kong Connect token
   - Tyk Dashboard token

3. **Environment**:
   - Bash shell
   - Network access to Kong and Tyk endpoints

## Usage

### Command Line

```bash
./migrate-kong-to-tyk.sh [options]
```

### Options

| Option                          | Description                                                  | Default                                |
|---------------------------------|--------------------------------------------------------------|----------------------------------------|
| `-h`, `--help`                  | Show help message.                                           | N/A                                    |
| `--konnect-addr URL`            | Kong Connect address.                                        | `https://us.api.konghq.com`           |
| `--konnect-control-plane NAME`  | Kong Control Plane name.                                     | `default`                             |
| `--konnect-token TOKEN`         | Kong Connect token. **(Required)**                          | N/A                                    |
| `--tyk-url URL`                 | Tyk Dashboard URL.                                           | `http://tyk-dashboard.localhost:3000` |
| `--tyk-token TOKEN`             | Tyk Auth token. **(Required)**                              | N/A                                    |
| `--data-dir PATH`               | Directory for storing JSON data files.                      | `./json-data`                         |

### Environment Variables

These can be used as an alternative to command-line options:

- `KONNECT_ADDR`
- `KONNECT_CONTROL_PLANE`
- `KONNECT_TOKEN`
- `TYK_DASHBOARD_URL`
- `TYK_AUTH_TOKEN`
- `DATA_DIR`

### Example Usage

Run the script and provide the necessary parameters:

```bash
./migrate-kong-to-tyk.sh \
    --konnect-addr <KONG_URL> \
    --konnect-control-plane <KONG_CONTROL_PLANE_NAME> \
    --konnect-token <KONG_TOKEN> \
    --tyk-url <TYK_URL> \
    --tyk-token <TYK_TOKEN>
```

Specify a custom directory for JSON data:

```bash
./migrate-kong-to-tyk.sh --data-dir /tmp/migration-data
```

## How It Works

1. **Export Kong Configuration**:
   - Uses `deck` to fetch Kong data and save it as JSON.

2. **Transform to OpenAPI**:
   - Processes the Kong configuration JSON and converts it to OpenAPI 3.0.3 format using `jq`.

3. **Split OpenAPI Files**:
   - Breaks the main OpenAPI file into individual JSON files for each service.

4. **Import to Tyk**:
   - Imports each OpenAPI file into Tyk via its Dashboard API.
   - Validates the API response to ensure successful import.

## Error Handling

- The script exits immediately on errors (`set -euo pipefail`).
- Missing parameters or invalid API responses trigger clear error messages.
- If the Tyk API response does not include `"Status": "OK"`, the process halts with an error.

## Customisation

- Modify default values by editing the script's configuration section.
- Adjust JSON processing logic (e.g., OpenAPI transformation) to match your specific Kong setup.

## Limitations

The script currently migrates the following API attributes:

- Name
- Listen path
- Upstream target (first route only)

Other API information, such as policies, security configurations, and documentation, must be migrated manually.

## Troubleshooting

- **Missing Dependencies**: Ensure `deck`, `jq`, and `curl` are installed and available in your `$PATH`.
- **Connection Errors**: Verify that the Kong and Tyk endpoints are accessible.
- **Invalid JSON**: Check the `kong-dump.json` and `kong-oas.json` files in the `DATA_DIR` for correctness.
