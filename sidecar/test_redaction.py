from redaction import redact_credentials


def test_provider_and_http_shapes_are_redacted():
    text = (
        "request failed: sk-live-abcdef123456 "
        "Authorization: Bearer abc.def.ghi apiKey=xyz"
    )
    redacted = redact_credentials(text)
    assert "sk-live-abcdef123456" not in redacted
    assert "abc.def.ghi" not in redacted
    assert "xyz" not in redacted


def test_redaction_is_idempotent():
    once = redact_credentials("password=hunter2 token: abc123")
    assert redact_credentials(once) == once
    assert "<redacted>" in once
