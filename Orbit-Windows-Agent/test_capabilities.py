"""Capabilities registry and GET /api/capabilities."""
import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient

import orbit_agent as agent
import orbit_capabilities as capabilities

TOKEN = "test-only-token-with-more-than-24-characters"


class RegistryTests(unittest.TestCase):
    def setUp(self):
        saved = capabilities.registered_features()
        self.addCleanup(self.restore, saved)

    @staticmethod
    def restore(saved):
        for name in capabilities.registered_features():
            capabilities.unregister_feature(name)
        for name in saved:
            capabilities.register_feature(name)

    def test_register_is_idempotent_and_keeps_registration_order(self):
        for name in capabilities.registered_features():
            capabilities.unregister_feature(name)
        capabilities.register_feature("events")
        capabilities.register_feature("openUrl")
        capabilities.register_feature("events")
        self.assertEqual(capabilities.registered_features(), ["events", "openUrl"])
        self.assertTrue(capabilities.has_feature("openUrl"))
        self.assertEqual(capabilities.capabilities_payload("9.9.9"), {"agentVersion": "9.9.9", "features": ["events", "openUrl"]})
        capabilities.unregister_feature("openUrl")
        capabilities.unregister_feature("openUrl")
        self.assertFalse(capabilities.has_feature("openUrl"))

    def test_only_the_designed_feature_strings_are_accepted(self):
        self.assertEqual(set(capabilities.KNOWN_FEATURES), {
            "events", "alerts", "downloads", "tasks", "powerAfter", "push", "openUrl", "hotkeys", "deck", "obs",
            "energy", "summary", "presentation", "streamDisplay", "secondScreen", "webcam", "powerCountdown"})
        for name in ("", "Events", "open-url", "open url", None, 7, "teleport", "x" * 41):
            with self.subTest(name=name), self.assertRaises(ValueError):
                capabilities.register_feature(name)

    def test_payload_defaults_to_the_agent_version_set_at_import(self):
        self.assertEqual(capabilities.capabilities_payload()["agentVersion"], agent.AGENT_VERSION)
        with self.assertRaises(ValueError):
            capabilities.set_agent_version("")

    def test_returned_lists_are_copies(self):
        listed = capabilities.registered_features()
        listed.append("bogus")
        payload = capabilities.capabilities_payload()
        payload["features"].append("bogus")
        self.assertNotIn("bogus", capabilities.registered_features())


class CapabilitiesRouteTests(unittest.TestCase):
    def test_agent_registers_its_foundation_features(self):
        with patch.object(agent, "API_TOKEN", TOKEN):
            client = TestClient(agent.app)
            self.addCleanup(client.close)
            response = client.get("/api/capabilities", headers={"Authorization": f"Bearer {TOKEN}"})
        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(set(body), {"agentVersion", "features"})
        self.assertEqual(body["agentVersion"], agent.AGENT_VERSION)
        for feature in ("events", "hotkeys", "openUrl"):
            self.assertIn(feature, body["features"])
        self.assertTrue(set(body["features"]) <= set(capabilities.KNOWN_FEATURES))


if __name__ == "__main__":
    unittest.main()
