"""Concurrency guard and logging-safety checks."""

import logging

import pytest
from fastapi import HTTPException

import app.main  # noqa: F401  (applies the logging configuration)
from app.services.report_locks import report_busy_guard
from app.services.reports_service import safe_error


def test_second_action_on_a_busy_report_is_rejected():
    with report_busy_guard("r1", "calculation"):
        with pytest.raises(HTTPException) as err:
            with report_busy_guard("r1", "calculation"):
                pass
        assert err.value.status_code == 409
        with report_busy_guard("r2", "calculation"):  # other reports unaffected
            pass
    with report_busy_guard("r1", "calculation"):  # released afterwards
        pass


@pytest.mark.parametrize("name", ["httpx", "httpcore", "hpack", "h2", "postgrest", "storage3"])
def test_http_libraries_never_log_below_warning(name):
    assert logging.getLogger(name).getEffectiveLevel() >= logging.WARNING


def test_safe_error_never_includes_message_text():
    class Boom(Exception):
        code = "23505"

    assert safe_error(Boom("Key (name)=(Alice 919876543210) already exists")) == "Boom (code 23505)"
