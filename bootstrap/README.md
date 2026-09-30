# Bootstrap (one-time manual steps)

Terraform stores its state in a DigitalOcean Spaces bucket. That bucket can't be
created by the Terraform that uses it (the backend has to exist before
`terraform init` can run), so it is the **only** resource created by hand.
Everything else in DigitalOcean is created by Terraform.

## 1. API token

1. DigitalOcean control panel → **API** → **Tokens** → **Generate New Token**.
2. Give it a name (e.g. `cartergrove-me-infra`), an expiry, and **Full Access**
   (or custom scopes covering every resource type this repo manages).
3. Save it somewhere safe (password manager); you'll export it as `DIGITALOCEAN_TOKEN`.

## 2. State bucket

1. Control panel → **Spaces Object Storage** → **Create Bucket**.
2. Region **NYC3**, name **`cartergrove-me-tfstate`**, file listing **Restricted**.
   No CDN.

   These values are hard-coded in every root module's `backend "s3"` block
   (`endpoints.s3` and `bucket`) and in each project's `terraform_remote_state`
   block. If you pick different ones, update them all:
   `grep -rn cartergrove-me-tfstate --include=*.tf .`

   Creating the first bucket starts the Spaces subscription (a flat monthly fee
   that includes 250 GiB; see DigitalOcean's pricing page for the current price).
   Buckets created later by Terraform (e.g. `games-downloads`) share it.

3. *(Recommended)* Turn on versioning so a bad state write can be rolled back.
   There's no control-panel toggle; use any S3 client, e.g. the AWS CLI with the
   Spaces key from step 3:

   ```powershell
   # AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY set as in step 4
   # Recent AWS CLIs add request checksums that Spaces can reject; only send them when required.
   $env:AWS_REQUEST_CHECKSUM_CALCULATION = "when_required"
   $env:AWS_RESPONSE_CHECKSUM_VALIDATION = "when_required"

   # --region is only needed for request signing; Spaces ignores its value.
   aws s3api put-bucket-versioning --bucket cartergrove-me-tfstate `
     --versioning-configuration Status=Enabled `
     --endpoint-url https://nyc3.digitaloceanspaces.com --region us-east-1

   # Should print "Status": "Enabled"
   aws s3api get-bucket-versioning --bucket cartergrove-me-tfstate `
     --endpoint-url https://nyc3.digitaloceanspaces.com --region us-east-1
   ```

   If the CLI fails with `argument of type 'NoneType' is not a container or
   iterable`, Spaces rejected the request (usually wrong credentials: the
   Access Key ID starts with `DO00` and is shorter than the secret) and the CLI
   crashed while formatting the error. Add `--debug` to see the real response.

## 3. Spaces access key

1. Control panel → **Spaces Object Storage** → **Access Keys** → **Create Access Key**.
2. **Full Access** (project configs also create buckets), named `cartergrove-me-infra`.
3. Copy the secret now; it is only shown once.

The same key is used twice, under two sets of names:

| Variable | Used by |
| --- | --- |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | the `s3` **backend** (reads/writes state) |
| `SPACES_ACCESS_KEY_ID` / `SPACES_SECRET_ACCESS_KEY` | the `digitalocean` **provider** (manages buckets) |

## 4. Environment variables

Credentials are only ever read from the environment. Never put them in `.tf`
or `.tfvars` files.

PowerShell (current session):

```powershell
$env:DIGITALOCEAN_TOKEN       = "dop_v1_..."
$env:AWS_ACCESS_KEY_ID        = "DO00..."
$env:AWS_SECRET_ACCESS_KEY    = "..."
$env:SPACES_ACCESS_KEY_ID     = $env:AWS_ACCESS_KEY_ID
$env:SPACES_SECRET_ACCESS_KEY          = $env:AWS_SECRET_ACCESS_KEY
$env:AWS_REQUEST_CHECKSUM_CALCULATION = "when_required"
$env:AWS_RESPONSE_CHECKSUM_VALIDATION = "when_required"
```

Bash:

```bash
export DIGITALOCEAN_TOKEN="dop_v1_..."
export AWS_ACCESS_KEY_ID="DO00..."
export AWS_SECRET_ACCESS_KEY="..."
export SPACES_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID"
export SPACES_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"
export AWS_REQUEST_CHECKSUM_CALCULATION="when_required"
export AWS_RESPONSE_CHECKSUM_VALIDATION="when_required"
```

To avoid retyping them, keep these lines in a script **outside this repo** and
run (PowerShell: dot-source) it at the start of a session.

## 5. Verify

```bash
cd shared
terraform init      # "Successfully configured the backend "s3"!"
terraform apply     # the first apply writes shared/terraform.tfstate to the bucket
cd ../projects/games
terraform init
terraform plan      # reads shared's outputs via terraform_remote_state
```

`shared/` must be applied at least once before any project can `plan`:
`terraform_remote_state` fails if `shared/terraform.tfstate` doesn't exist yet.

## Note: no state locking

State locking is off. That's fine while one person runs `apply` locally, but
don't run two applies against the same root module at once. Revisit when CI
starts applying (grovecj/cartergrove-me-infra#5).
