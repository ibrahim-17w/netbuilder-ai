import unittest

import pt_autopilot as pt


class PktDiscoveryTests(unittest.TestCase):
    def test_common_packet_tracer_labels_are_classified(self):
        self.assertEqual(pt._canvas_device_token("R1"), ("R1", "router"))
        self.assertEqual(pt._canvas_device_token("SW1"), ("SW1", "switch"))
        self.assertEqual(pt._canvas_device_token("PC1"), ("PC1", "pc"))
        self.assertEqual(pt._canvas_device_token("SRV1"), ("SRV1", "server"))
        self.assertEqual(pt._canvas_device_token("HQ_Router"),
                         ("HQ_ROUTER", "router"))

    def test_unrelated_canvas_text_is_not_treated_as_a_device(self):
        self.assertIsNone(pt._canvas_device_token("Configuration"))
        self.assertIsNone(pt._canvas_device_token("FastEthernet0/1"))
        self.assertIsNone(pt._canvas_device_token("192.168.10.1"))

    def test_service_evidence_requires_a_saved_table_value(self):
        self.assertTrue(
            pt._service_saved_evidence(
                "dhcp", "Pool Name serverPool Gateway 192.168.10.1"
            )
        )
        self.assertFalse(pt._service_saved_evidence("dhcp", "Pool Name"))
        self.assertTrue(
            pt._service_saved_evidence(
                "dns", "Resource Records srv1 192.168.10.11"
            )
        )

    def test_service_rule_evidence_distinguishes_state_only_services(self):
        self.assertEqual(
            pt._service_rule_evidence(
                "ftp", "FTP Service On User Name Add Delete alice"
            )["mode"],
            "saved_table_or_record",
        )
        self.assertEqual(
            pt._service_rule_evidence("ntp", "NTP Service On")["mode"],
            "state_only",
        )

    def test_cli_context_classifier_requires_the_right_prompt_mode(self):
        self.assertEqual(pt._cli_prompt_mode("R1(config-if)#"), "interface")
        self.assertEqual(pt._cli_prompt_mode("R1(config-router)#"), "router")
        self.assertEqual(pt._cli_prompt_mode("R1(config-ext-nacl)#"), "acl")
        self.assertEqual(
            pt._command_requirement("ip address 192.168.1.1 255.255.255.0",
                                    {"kind": "interface"}),
            "interface",
        )
        self.assertEqual(
            pt._command_requirement("network 10.0.0.0 0.0.0.3 area 0",
                                    {"kind": "router"}),
            "router",
        )
        self.assertFalse(pt._prompt_matches("config", "interface"))

    def test_service_build_modes_are_explicit(self):
        self.assertEqual(
            pt._service_verification_mode("ftp", {"users": [{}]}, True),
            "rules_verified",
        )
        self.assertEqual(
            pt._service_verification_mode("ntp", {"on": True}, True),
            "state_only",
        )
        self.assertEqual(
            pt._service_verification_mode("ftp", {"users": [{}]}, False),
            "failed",
        )

    def test_helper_processes_use_hidden_windows_flags(self):
        options = pt._hidden_subprocess_options()
        if pt.os.name == "nt":
            self.assertNotEqual(options["creationflags"] & 0x08000000, 0)
            self.assertEqual(
                options["startupinfo"].wShowWindow,
                pt.subprocess.SW_HIDE,
            )
        else:
            self.assertEqual(options, {})

    def test_audit_summary_preserves_device_and_failure_counts(self):
        report = pt._audit_summary(
            [
                {
                    "type": "router",
                    "findings": [{"severity": "high"}],
                    "interfaces": [
                        {"status": "up"},
                        {"status": "administratively down"},
                    ],
                },
                {
                    "type": "server",
                    "findings": [{"severity": "info"}],
                    "services": [
                        {"state": "on", "saved_data": True},
                        {
                            "state": "unknown",
                            "saved_data": False,
                            "verification_mode": "state_only",
                        },
                    ],
                },
            ],
            [{"x": 10, "y": 20, "pixels": 3}],
            {"devices": [{"name": "R1"}]},
        )
        self.assertEqual(report["device_count"], 2)
        self.assertEqual(report["by_type"]["server"], 1)
        self.assertEqual(report["severity"]["high"], 1)
        self.assertEqual(report["interfaces"]["administratively_down"], 1)
        self.assertEqual(report["services"]["checked"], 2)
        self.assertEqual(report["services"]["saved_data"], 1)
        self.assertEqual(report["services"]["state_only"], 1)
        self.assertTrue(report["canvas_discovery_used"])

    def test_cli_evidence_omits_prompts_and_command_echoes(self):
        self.assertEqual(
            pt._evidence_lines(
                "R1# show ip route\n"
                "Codes: C - connected\n"
                "C 192.168.10.0/24 is directly connected\n"
                "% Invalid input detected\n"
            ),
            ["Codes: C - connected", "C 192.168.10.0/24 is directly connected"],
        )


if __name__ == "__main__":
    unittest.main()
