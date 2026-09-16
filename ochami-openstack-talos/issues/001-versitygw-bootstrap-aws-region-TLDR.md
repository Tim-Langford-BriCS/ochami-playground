# 001 — TL;DR: why an S3 gateway on OpenStack wants an AWS region

*The short version. Full write-up, code paths, rejected alternatives and the safety proof: [`001-versitygw-bootstrap-aws-region.md`](001-versitygw-bootstrap-aws-region.md).*

**The symptom:** the last command of §5.5 fails.

```
head$ sudo systemctl enable --now versitygw-bootstrap.service
Job for versitygw-bootstrap.service failed because the control process exited with error code.
```

```
Provided region_name 'DL-Rack-' doesn't match a supported format.
```

⚠ **If you are on rack 11 or 12, you will not see this — you will see nothing at all, at first.**
An AZ whose derived region is still a *valid* name (`DL-Rack-11` → `DL-Rack-1`) lets the AWS CLI
correct itself and retry, so §5.5 completes normally and `versitygw-bootstrap` fails only on its
**next** run, with `BucketAlreadyExists`. Same cause, same fix, and it will find you after a
reboot rather than at the prompt. The full table is in
[Who else sees this](001-versitygw-bootstrap-aws-region.md#who-else-sees-this).

---

## Why there's a region at all

Because "S3-compatible" means compatible with S3's **authentication scheme**, and that scheme has a region field baked into the cryptography — not into any AWS infrastructure.

AWS Signature V4 doesn't sign requests with your secret key directly. It derives a signing key by chaining HMACs:

```
kDate    = HMAC("AWS4" + secret_key, "20260803")
kRegion  = HMAC(kDate,    "us-east-1")     ← the region is an input here
kService = HMAC(kRegion,  "s3")
kSigning = HMAC(kService, "aws4_request")
```

The region is effectively a **shared salt**. Client and server each derive the key independently and compare signatures, so if the two use different region strings the keys differ and nothing authenticates. The client also declares its choice in the header, which is what versitygw parses and checks:

```
Authorization: AWS4-HMAC-SHA256 Credential=<key>/20260803/us-east-1/s3/aws4_request, ...
```

So there is no AWS in the picture. There is a protocol that versitygw implements faithfully, including the part where both ends must agree on a string.

**And `us-east-1` specifically?** Only because that's what versitygw defaults to and nobody changed it:

```
head$ sudo podman exec versitygw versitygw --help | grep -- --region
   --region value, -r value    s3 region string (default: "us-east-1") [$VGW_REGION]
```

The value is arbitrary — you could set both sides to `bristol` and it would work identically. What isn't optional is **agreement**. Right now the server says `us-east-1`, so the client must too. That's the entire constraint.

The bug was never that a region is required. It's that nobody told the CLI which one, so it went and guessed from cloud metadata — and guessed from an OpenStack availability-zone name.

## The fix

Two things, in one file:

- **`AWS_EC2_METADATA_DISABLED=true`** — stop the CLI guessing. This is the actual fix; it removes the guess entirely rather than correcting it.
- **`AWS_REGION` / `AWS_DEFAULT_REGION` = `us-east-1`** — tell it the answer, matching the server. Two spellings because CLI v1 reads one and v2 the other.

It goes in a systemd **drop-in** rather than the unit file, because the unit belongs to the `versitygw-quadlet` RPM and an upgrade would revert an edit.

## How to use it

Run this on `rocky@tw-head`:

```
sudo mkdir -p /etc/systemd/system/versitygw-bootstrap.service.d
sudo tee /etc/systemd/system/versitygw-bootstrap.service.d/10-aws-region.conf <<'EOF'
[Service]
Environment=AWS_EC2_METADATA_DISABLED=true
Environment=AWS_REGION=us-east-1
Environment=AWS_DEFAULT_REGION=us-east-1
EOF
sudo systemctl daemon-reload
sudo systemctl restart versitygw-bootstrap.service
```

Then confirm it completed — you want to see `fabricmanager` this time, which the failed run never reached:

```
sudo journalctl -u versitygw-bootstrap.service --no-pager -n 30 \
  | grep -E "processing|bucket|COMPLETE"
```

Expect `processing 'slurmd'` → `using existing credentials` → `IAM user exists` → `creating bucket slurmd-bucket`, then the same for `fabricmanager`, ending `bootstrap: COMPLETE`.

Prove the buckets exist:

```
sudo AWS_EC2_METADATA_DISABLED=true AWS_REGION=us-east-1 \
  aws --profile vgw-root --endpoint-url http://127.0.0.1:7070 s3 ls
```

Expect `fabricmanager-bucket` and `slurmd-bucket`. Note you pass the two variables by hand here — the drop-in covers only the systemd unit, so anything *you* type still needs them until §8.3 runs `aws configure set region us-east-1` and makes it permanent for your shell.

Then resume §5.5's checkpoint:

```
for s in versitygw registry; do echo -n "$s: "; systemctl is-active $s; done
```

Both `active` → on to §5.6.

**The one thing to carry forward:** if you ever see `AuthorizationHeaderMalformed` against this gateway in a later section, it's this same disagreement, not a credentials problem. Check that whatever is talking to port 7070 is signing with `us-east-1`.
