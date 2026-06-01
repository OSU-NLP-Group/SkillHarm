"""Tests for attack filter output."""

import json
import os
import pytest

OUTPUT_DIR = "/root/output"
FILTER_JSON = os.path.join(OUTPUT_DIR, "filter_result.json")
ATTACK_JSON = "/root/attack_design.json"


@pytest.fixture(scope="module")
def result():
    assert os.path.isfile(FILTER_JSON), f"Missing {FILTER_JSON}"
    with open(FILTER_JSON) as f:
        return json.load(f)


@pytest.fixture(scope="module")
def attack():
    assert os.path.isfile(ATTACK_JSON), f"Missing {ATTACK_JSON}"
    with open(ATTACK_JSON) as f:
        return json.load(f)


class TestStructure:
    def test_filter_result_exists(self):
        assert os.path.isfile(FILTER_JSON)

    def test_required_fields(self, result):
        for field in ["pair", "risk_type", "design_agent_id", "verdict", "reasons", "summary"]:
            assert field in result, f"Missing field: {field}"

    def test_verdict_is_valid(self, result):
        assert result["verdict"] in ("keep", "discard"), \
            f"verdict must be 'keep' or 'discard', got '{result['verdict']}'"

    def test_reasons_is_list(self, result):
        assert isinstance(result["reasons"], list), "reasons must be a list"
        assert len(result["reasons"]) >= 1, "Must provide at least one reason"

    def test_reasons_have_required_fields(self, result):
        for i, reason in enumerate(result["reasons"]):
            assert "category" in reason, f"Reason {i} missing 'category'"
            assert "description" in reason, f"Reason {i} missing 'description'"

    def test_summary_not_empty(self, result):
        assert len(result.get("summary", "")) >= 50, \
            "summary must be at least 50 characters"


class TestCoherence:
    def test_pair_matches(self, result, attack):
        assert result["pair"] == attack["pair"], \
            f"Pair mismatch: {result['pair']} vs {attack['pair']}"

    def test_risk_type_matches(self, result, attack):
        assert result["risk_type"] == attack["risk_type"], \
            f"Risk type mismatch: {result['risk_type']} vs {attack['risk_type']}"
