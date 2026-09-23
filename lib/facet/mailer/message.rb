require 'securerandom'
require 'time'

module Facet
  module Mailer
    class Message
      attr_accessor :from, :reply_to, :subject, :text_body, :html_body
      attr_reader :to, :cc, :bcc, :attachments, :headers

      def initialize
        @to = []
        @cc = []
        @bcc = []
        @attachments = []
        @headers = {}
        @message_id = "#{SecureRandom.hex(16)}@facet"
      end

      def to=(value)
        @to = Array(value)
      end

      def cc=(value)
        @cc = Array(value)
      end

      def bcc=(value)
        @bcc = Array(value)
      end

      def []=(header, value)
        headers[header.to_s] = value
      end

      def add_attachment(filename, content, mime_type: 'application/octet-stream')
        attachments << { filename: filename, content: content, mime_type: mime_type }
      end

      def all_recipients
        (to + cc + bcc).compact
      end

      def multipart_body?
        !text_body.nil? && !html_body.nil?
      end

      def to_s
        raise ArgumentError, 'message requires a from address' unless from
        raise ArgumentError, 'message requires at least one recipient (to/cc/bcc)' if all_recipients.empty?
        raise ArgumentError, 'message requires a text_body or html_body' if text_body.nil? && html_body.nil?

        lines = header_lines
        body = build_body

        lines.concat(body[:headers])
        lines << ''
        lines << body[:content]
        lines.join("\r\n")
      end

      private

      def header_lines
        lines = []
        lines << "From: #{from}"
        lines << "To: #{to.join(', ')}" unless to.empty?
        lines << "Cc: #{cc.join(', ')}" unless cc.empty?
        lines << "Reply-To: #{reply_to}" if reply_to
        lines << "Subject: #{encode_header(subject.to_s)}"
        lines << "Date: #{Time.now.httpdate}"
        lines << "Message-ID: <#{@message_id}>"
        lines << 'MIME-Version: 1.0'
        headers.each { |name, value| lines << "#{name}: #{value}" }
        lines
      end

      def build_body
        alternative = build_alternative_part
        return alternative if attachments.empty?

        boundary = new_boundary('mixed')
        content = +"--#{boundary}\r\n"
        content << alternative[:headers].join("\r\n")
        content << "\r\n\r\n"
        content << alternative[:content]
        attachments.each { |attachment| content << "\r\n--#{boundary}\r\n#{attachment_part(attachment)}" }
        content << "\r\n--#{boundary}--"
        { headers: ["Content-Type: multipart/mixed; boundary=\"#{boundary}\""], content: content }
      end

      def build_alternative_part
        if multipart_body?
          boundary = new_boundary('alt')
          content = +"--#{boundary}\r\n"
          content << "Content-Type: text/plain; charset=UTF-8\r\n\r\n#{text_body}"
          content << "\r\n--#{boundary}\r\n"
          content << "Content-Type: text/html; charset=UTF-8\r\n\r\n#{html_body}"
          content << "\r\n--#{boundary}--"
          { headers: ["Content-Type: multipart/alternative; boundary=\"#{boundary}\""], content: content }
        elsif html_body
          { headers: ['Content-Type: text/html; charset=UTF-8'], content: html_body }
        else
          { headers: ['Content-Type: text/plain; charset=UTF-8'], content: text_body }
        end
      end

      def attachment_part(attachment)
        header = +"Content-Type: #{attachment[:mime_type]}; name=\"#{attachment[:filename]}\"\r\n"
        header << "Content-Transfer-Encoding: base64\r\n"
        header << "Content-Disposition: attachment; filename=\"#{attachment[:filename]}\"\r\n\r\n"
        header << [attachment[:content]].pack('m0').scan(/.{1,76}/).join("\r\n")
        header
      end

      def new_boundary(label)
        "facet-#{label}-#{SecureRandom.hex(8)}"
      end

      def encode_header(text)
        return text if text.ascii_only?

        "=?UTF-8?B?#{[text].pack('m0')}?="
      end
    end
  end
end
