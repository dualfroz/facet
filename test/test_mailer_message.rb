require 'minitest/autorun'
require 'prism'

class MailerMessageTest < Minitest::Test
  def setup
    @message = Prism::Mailer::Message.new
    @message.from = 'sender@example.com'
    @message.to = 'receiver@example.com'
    @message.subject = 'Test subject'
  end

  def test_requires_a_from_address
    @message.from = nil
    @message.text_body = 'body'
    assert_raises(ArgumentError) { @message.to_s }
  end

  def test_requires_at_least_one_recipient
    @message.to = []
    @message.text_body = 'body'
    assert_raises(ArgumentError) { @message.to_s }
  end

  def test_requires_a_body
    assert_raises(ArgumentError) { @message.to_s }
  end

  def test_to_cc_bcc_coerce_a_single_address_into_an_array
    @message.to = 'a@example.com'
    @message.cc = 'b@example.com'
    @message.bcc = 'c@example.com'
    assert_equal ['a@example.com'], @message.to
    assert_equal %w[a@example.com b@example.com c@example.com], @message.all_recipients
  end

  def test_plain_text_only_message_has_a_single_text_content_type
    @message.text_body = 'hello world'
    raw = @message.to_s
    assert_includes raw, "Content-Type: text/plain; charset=UTF-8\r\n\r\nhello world"
    refute_includes raw, 'multipart'
  end

  def test_html_only_message_has_a_single_html_content_type
    @message.html_body = '<p>hello</p>'
    raw = @message.to_s
    assert_includes raw, "Content-Type: text/html; charset=UTF-8\r\n\r\n<p>hello</p>"
    refute_includes raw, 'multipart'
  end

  def test_text_and_html_together_build_a_multipart_alternative_part
    @message.text_body = 'plain body'
    @message.html_body = '<p>html body</p>'
    raw = @message.to_s
    assert_match(/Content-Type: multipart\/alternative; boundary="([^"]+)"/, raw)
    boundary = raw[/boundary="([^"]+)"/, 1]
    assert_includes raw, "--#{boundary}\r\nContent-Type: text/plain"
    assert_includes raw, "--#{boundary}\r\nContent-Type: text/html"
    assert_includes raw, "--#{boundary}--"
  end

  def test_attachment_wraps_the_body_in_multipart_mixed_and_base64_encodes_content
    @message.text_body = 'see attached'
    @message.add_attachment('data.bin', "\xFF\x00\xFE binary".b, mime_type: 'application/octet-stream')
    raw = @message.to_s
    assert_match(/Content-Type: multipart\/mixed; boundary="([^"]+)"/, raw)
    assert_includes raw, 'Content-Disposition: attachment; filename="data.bin"'
    assert_includes raw, 'Content-Transfer-Encoding: base64'
    encoded = raw[/Content-Disposition: attachment; filename="data\.bin"\r\n\r\n(.+?)\r\n--/m, 1]
    assert_equal "\xFF\x00\xFE binary".b, encoded.unpack1('m0')
  end

  def test_headers_writer_adds_a_custom_header_line
    @message.text_body = 'body'
    @message['X-Custom'] = 'yes'
    assert_includes @message.to_s, "X-Custom: yes\r\n"
  end

  def test_reply_to_and_cc_appear_in_headers
    @message.text_body = 'body'
    @message.cc = 'cc@example.com'
    @message.reply_to = 'reply@example.com'
    raw = @message.to_s
    assert_includes raw, "Cc: cc@example.com\r\n"
    assert_includes raw, "Reply-To: reply@example.com\r\n"
  end

  def test_non_ascii_subject_is_mime_encoded
    @message.subject = "Zaproszenie na przyj\u0119cie"
    @message.text_body = 'body'
    subject_line = @message.to_s.lines.find { |l| l.start_with?('Subject:') }
    assert_match(/Subject: =\?UTF-8\?B\?.+\?=/, subject_line)
  end

  def test_ascii_subject_is_left_untouched
    @message.text_body = 'body'
    subject_line = @message.to_s.lines.find { |l| l.start_with?('Subject:') }
    assert_equal 'Subject: Test subject', subject_line.chomp("\n")
  end
end
