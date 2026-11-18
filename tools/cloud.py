"""Check the funding boundary and run the selected Terraform deployment."""

import argparse
import datetime as dt
import ipaddress
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
ACCOUNT = r"[0-9]{12}"
REGION = r"[a-z]{2}-[a-z]+-[0-9]+"
PREFIX = "project-drive/"


def credential_environment(profile, region):
    env = os.environ.copy()
    for key in (
        "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN",
        "AWS_SECURITY_TOKEN", "AWS_WEB_IDENTITY_TOKEN_FILE", "AWS_ROLE_ARN",
        "AWS_ROLE_SESSION_NAME", "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI",
        "AWS_CONTAINER_CREDENTIALS_FULL_URI",
    ):
        env.pop(key, None)
    env.update(
        AWS_PROFILE=profile, AWS_DEFAULT_PROFILE=profile, AWS_REGION=region,
        AWS_DEFAULT_REGION=region, AWS_EC2_METADATA_DISABLED="true",
        AWS_IGNORE_CONFIGURED_ENDPOINT_URLS="true", AWS_PAGER="",
    )
    return env


def aws(env, region, *args):
    command = [
        "aws", *args, "--region", region, "--profile", env["AWS_PROFILE"],
        "--no-cli-pager", "--cli-connect-timeout", "6", "--cli-read-timeout", "8",
        "--output", "json",
    ]
    output = subprocess.check_output(command, env=env, text=True, timeout=30)
    return json.loads(output) if output.strip() else None


def require_funding(identity, plan, account_id, minimum_credits, minimum_days):
    if identity.get("Account") != account_id or plan.get("accountId") != account_id:
        raise ValueError("The signed-in project differs from the deployment configuration.")
    if (plan.get("accountPlanType"), plan.get("accountPlanStatus")) != ("FREE", "ACTIVE"):
        raise ValueError("Use an active Free plan, or explicitly opt into billable AWS usage.")
    credits = plan.get("accountPlanRemainingCredits") or {}
    if credits.get("unit") != "USD" or credits.get("amount", 0) < minimum_credits:
        raise ValueError(f"The project needs at least USD {minimum_credits:g} in credits.")
    raw_expiry = plan.get("accountPlanExpirationDate")
    if not isinstance(raw_expiry, str):
        raise ValueError("The Free plan expiry could not be verified.")
    expiry = dt.datetime.fromisoformat(raw_expiry.replace("Z", "+00:00"))
    if expiry.tzinfo is None:
        expiry = expiry.replace(tzinfo=dt.timezone.utc)
    if expiry <= dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=minimum_days):
        raise ValueError(f"The AWS Free plan needs more than {minimum_days} days remaining.")
    print(f"Active Free plan. USD {credits['amount']:g} remains. Expires {expiry.date()}.",
          flush=True)


def verify_billing(args, env, identity, account_id):
    if identity.get("Account") != account_id:
        raise ValueError("The signed-in AWS account differs from the deployment configuration.")
    if args.allow_paid:
        print("Billable AWS usage accepted for this deployment.", flush=True)
        return
    # Free Tier is a billing API in us-east-1. It creates no Regional resources.
    plan = aws(env, "us-east-1", "freetier", "get-account-plan-state")
    minimum = args.minimum_credits
    if minimum is None:
        minimum = 0.53 if args.stack == "pilot" else 8.83
    if not math.isfinite(minimum) or minimum <= 0:
        raise ValueError("Set minimum credits to the positive USD amount expected for the trial.")
    require_funding(identity, plan, account_id, minimum, args.minimum_days)


def comparable_settings(settings):
    normalized = settings.copy()
    roles = normalized.get("mount_source_roles")
    if isinstance(roles, dict):
        # Terraform can write an omitted optional attribute as null in the saved plan.
        normalized["mount_source_roles"] = {key: arn for key, arn in roles.items()
                                            if arn is not None}
    return normalized


def deploy(args):
    settings = json.loads(args.vars.read_text(encoding="utf-8-sig"))
    account = settings["account_id"]
    region = settings["region"]
    if not re.fullmatch(ACCOUNT, account) or not re.fullmatch(REGION, region):
        raise ValueError("Set account_id and region to the values from AWS Settings.")
    env = credential_environment(args.profile, region)
    for key in list(env):
        if key.startswith(("TF_CLI_ARGS", "TF_VAR_")):
            del env[key]
    identity = aws(env, region, "sts", "get-caller-identity")
    verify_billing(args, env, identity, account)
    if args.action == "check":
        return
    working_dir = ROOT / "infra" / args.stack
    terraform = ["terraform", f"-chdir={working_dir}"]
    plan_file = working_dir / "deployment.tfplan"
    if args.action == "plan":
        # A failed replacement plan must never leave a previously saved plan eligible.
        plan_file.unlink(missing_ok=True)
        subprocess.run(terraform + ["init", "-input=false"], env=env, check=True)
        subprocess.run(
            terraform + [
                "plan", "-input=false", f"-var-file={args.vars.resolve()}",
                f"-out={plan_file}",
            ],
            env=env, check=True,
        )
        return
    reviewed = json.loads(subprocess.check_output(
        terraform + ["show", "-json", str(plan_file)], env=env, text=True,
    ))
    variables = {key: reviewed["variables"].get(key, {}).get("value") for key in settings}
    if comparable_settings(variables) != comparable_settings(settings):
        raise ValueError("The saved plan differs from the supplied configuration. Plan again.")
    if any("delete" in item["change"]["actions"] for item in reviewed.get("resource_changes", [])):
        raise ValueError("The saved plan includes a deletion or replacement.")
    subprocess.run(terraform + ["apply", "-input=false", str(plan_file)], env=env, check=True)
    plan_file.unlink()


def client_settings(path, device):
    settings = json.loads(path.read_text(encoding="utf-8-sig"))
    profile = settings["profile"]
    role = settings["role_arn"]
    role_match = re.fullmatch(rf"arn:aws:iam::({ACCOUNT}):role/project-drive-{device}-mount", role)
    if not role_match or not re.fullmatch(r"[A-Za-z0-9_.-]+", profile):
        raise ValueError(f"Set a dedicated profile and the Terraform {device} mount role ARN.")
    endpoint = settings["bucket_endpoint"]
    account = role_match[1]
    endpoint_match = re.fullmatch(rf"https://(project-drive-{account}-({REGION}))\.s3\.\2\.amazonaws\.com", endpoint)
    if not endpoint_match:
        raise ValueError("Use the bucket_endpoint output from the same pilot deployment.")
    host = settings["db_host"].lower()
    try:
        is_tailnet = ipaddress.IPv4Address(host) in ipaddress.IPv4Network("100.64.0.0/10")
    except ipaddress.AddressValueError:
        is_tailnet = bool(re.fullmatch(r"[a-z0-9-]+\.[a-z0-9-]+\.ts\.net", host))
    if not is_tailnet and not (device == "mac" and host == "127.0.0.1"):
        raise ValueError("Use the Mac's loopback or the index host's private Tailscale address.")
    return profile, role, endpoint, host, endpoint_match[2], endpoint_match[1]


def check_mount(settings):
    profile, role, _, _, region, bucket = settings
    env = credential_environment(profile, region)
    expected = role.replace(":iam:", ":sts:").replace(":role/", ":assumed-role/") + "/"
    identity = aws(env, region, "sts", "get-caller-identity")
    if not identity.get("Arn", "").startswith(expected):
        raise ValueError("The selected AWS profile did not assume the required device mount role.")
    aws(env, region, "s3api", "list-objects-v2", "--bucket", bucket, "--prefix", PREFIX,
        "--max-keys", "1", "--no-paginate", "--query", "KeyCount")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    for action in ("check", "plan", "apply"):
        cmd = commands.add_parser(action)
        cmd.add_argument("--stack", choices=("pilot", "hosted"), default="pilot")
        cmd.add_argument("--vars", type=Path, required=True)
        cmd.add_argument("--profile", required=True)
        cmd.add_argument("--allow-paid", action="store_true",
                         help="Explicitly accept standard AWS charges and skip the Free plan check.")
        cmd.add_argument("--minimum-credits", type=float, metavar="USD",
                         help="Projected spend. Defaults to the modeled pilot cost.")
        cmd.add_argument("--minimum-days", type=int, default=0, choices=range(0, 181),
                         metavar="0-180", help="Require enough time for the planned test window.")
    for action in ("client-settings", "check-mount"):
        cmd = commands.add_parser(action)
        cmd.add_argument("--config", type=Path, required=True)
        cmd.add_argument("--device", choices=("mac", "windows"), required=True)
    args = parser.parse_args()
    try:
        if args.action in ("client-settings", "check-mount"):
            settings = client_settings(args.config, args.device)
            if args.action == "client-settings":
                print("\t".join(settings))
            else:
                check_mount(settings)
        else:
            deploy(args)
    except (KeyError, TypeError, ValueError, OSError, subprocess.SubprocessError) as exc:
        if isinstance(exc, subprocess.CalledProcessError):
            print(f"{Path(exc.cmd[0]).name} exited with status {exc.returncode}. "
                  "See the tool output for details.", file=sys.stderr)
        else:
            print(f"Project Drive: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
