# PowerEdge R640 Test Fixtures

These fixtures contain Redfish API responses collected from a Dell PowerEdge R640 server.

## Directory Structure

The directory structure mirrors the Redfish API paths:

```
PowerEdge-R640/
└── redfish/
    └── v1/
        ├── Systems/
        │   └── System.Embedded.1/
        │       └── index.json
        ├── Managers/
        │   └── iDRAC.Embedded.1/
        │       └── index.json
        └── LicenseService/
            └── Licenses/
                ├── index.json
                └── FD00000011364489.json
```

## Data Collection

These fixtures were collected from a PowerEdge R640 with the following specifications:
- Service Tag: BSG7KP2
- iDRAC Version: 7.00.00.172
- License Type: Production (iDRAC9 Enterprise License)

The data was collected using curl commands against the Redfish API endpoints:

```bash
# System Information
curl -k -u root:calvin https://127.0.0.1/redfish/v1/Systems/System.Embedded.1

# iDRAC Information
curl -k -u root:calvin https://127.0.0.1/redfish/v1/Managers/iDRAC.Embedded.1

# License Collection
curl -k -u root:calvin https://127.0.0.1/redfish/v1/LicenseService/Licenses

# License Details
curl -k -u root:calvin https://127.0.0.1/redfish/v1/LicenseService/Licenses/FD00000011364489
```

## Usage

These fixtures are used in the test suite to verify the functionality of the idrac gem without requiring a live iDRAC connection. The paths in the fixtures match the actual Redfish API paths, making it easy to understand the relationship between the test data and the actual API. 