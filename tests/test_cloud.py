from types import SimpleNamespace
import unittest
from unittest.mock import patch

from tools import cloud


class DeploymentTests(unittest.TestCase):
    def test_mac_only_plan_accepts_missing_or_null_windows_role(self):
        roles = {"mac": "example-mac-role"}
        expected = cloud.comparable_settings({"mount_source_roles": roles})
        planned = cloud.comparable_settings({"mount_source_roles": roles | {"windows": None}})
        self.assertEqual(expected, planned)
        added = cloud.comparable_settings({"mount_source_roles": roles | {"windows": "example-windows-role"}})
        self.assertNotEqual(expected, added)

    @patch.object(cloud, "aws")
    def test_paid_opt_in_still_confirms_account(self, aws):
        args = SimpleNamespace(allow_paid=True)
        with self.assertRaisesRegex(ValueError, "account differs"):
            cloud.verify_billing(args, {}, {"Account": "0" * 12}, "123456789012")
        cloud.verify_billing(args, {}, {"Account": "123456789012"}, "123456789012")
        aws.assert_not_called()

    @patch.object(cloud, "aws")
    def test_default_flow_rejects_paid_plan(self, aws):
        account = "123456789012"
        aws.return_value = {"accountId": account, "accountPlanType": "PAID",
                            "accountPlanStatus": "ACTIVE"}
        args = SimpleNamespace(allow_paid=False, minimum_credits=None, minimum_days=0,
                               stack="pilot")
        with self.assertRaisesRegex(ValueError, "Free plan"):
            cloud.verify_billing(args, {}, {"Account": account}, account)
        aws.assert_called_once_with({}, "us-east-1", "freetier", "get-account-plan-state")
