# Operations Guide

This document contains instructions for maintaining the `dogeos-rpc-package` infrastructure. These commands are intended for **operators** and **developers**, not for general node users.

## Snapshot Automation

The `create_snapshot.sh` script automates the backup of Dogecoin and L1 Interface data. It stops services, snapshots data, and uploads to S3.

### Prerequisites (Host Machine)

Since the scheduler is run directly on the host, you need to verify dependencies.

1.  **Dependencies**:
    ```bash
    # Ubuntu/Debian
    sudo apt-get update && sudo apt-get install -y zstd awscli
    ```

    Ensure Docker is installed and you can run `docker compose` commands.

2.  **AWS Credentials**:
    Configure AWS CLI on the host:
    ```bash
    aws configure
    ```
    Or ensure environment variables (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`) are set in the crontab environment.

### Setting up Cron (Host)

1.  Open crontab:
    ```bash
    crontab -e
    ```

2.  Add the following line (adjust path to where you cloned the repo):
    
    *Example: Run weekly on Sunday at 03:00 UTC*

    ```cron
    0 3 * * 0 cd /path/to/dogeos-rpc-package && ./scripts/create_snapshot.sh all >> /var/log/dogeos_snapshot.log 2>&1
    ```

    *Important: Ensure the script is executable (`chmod +x scripts/create_snapshot.sh`)*

### Manual Trigger

To create a snapshot immediately:

```bash
cd /path/to/dogeos-rpc-package
./scripts/create_snapshot.sh all
```
