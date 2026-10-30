require 'net/http'
require 'uri'
require 'openssl'
require 'base64'
require 'tmpdir'

module JFBuild
  class HTTP
    def json(method, address, fields: {}, body: nil)
      uri = URI(address)
      if method == :get
        uri.query = URI.encode_www_form(URI.decode_www_form(uri.query.to_s) + fields.to_a)
        request = Net::HTTP::Get.new(uri)
      else
        request = Net::HTTP::Post.new(uri)
        body ? (request['Content-Type'] = 'application/json'; request.body = JSON.generate(body)) : request.set_form_data(fields)
      end
      result = JSON.parse(send_request(uri, request).body)
      raise Error, '上传服务未返回有效的结果对象。' unless result.is_a?(Hash)
      result
    rescue JSON::ParserError, URI::InvalidURIError
      raise Error, '上传地址或服务返回格式无效，请检查配置后重试。'
    end

    def upload(address, fields, file)
      uri = URI(address)
      File.open(file, 'rb') do |stream|
        request = Net::HTTP::Post.new(uri)
        request.set_form(fields.to_a + [['file', stream, { filename: File.basename(file) }]], 'multipart/form-data')
        send_request(uri, request)
      end
      true
    rescue URI::InvalidURIError
      raise Error, '服务返回的文件上传地址无效。'
    end

    private

    def send_request(uri, request)
      raise Error, '上传服务地址必须使用 HTTPS。' unless uri.is_a?(URI::HTTPS) && uri.host && uri.userinfo.nil?
      client = Net::HTTP.new(uri.host, uri.port)
      client.use_ssl = true
      { 'open_timeout' => 20, 'read_timeout' => 600, 'write_timeout' => 600 }.each do |key, default|
        client.public_send("#{key}=", default)
      end
      client.max_retries = 0
      response = client.start { |http| http.request(request) }
      raise Error, "上传服务返回 HTTP #{response.code}，请稍后单独重试。" unless response.is_a?(Net::HTTPSuccess)
      response
    rescue IOError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, SocketError
      raise Error, '上传网络连接失败；请先核对服务端状态再重试，避免重复上传。'
    end
  end

  class PgyerUpload
    API = 'https://www.pgyer.com/apiv2/app'.freeze

    def initialize(config, http: nil, sleeper: ->(seconds) { sleep(seconds) }, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @config, @http, @sleeper, @clock = config, http || HTTP.new, sleeper, clock
    end

    def validate!
      data = @config.section('pgyer')
      unless data['api_key'].is_a?(String) && !data['api_key'].strip.empty?
        raise Error, '请填写 pgyer.api_key。'
      end
      begin
        type = Integer(data.fetch('install_type', 2).to_s, 10)
      rescue ArgumentError, TypeError
        type = nil
      end
      raise Error, 'pgyer.install_type 只能为 1（公开）、2（密码）或 3（邀请）。' unless [1, 2, 3].include?(type)
      if type == 2 && (!data['password'].is_a?(String) || data['password'].empty?)
        raise Error, '密码安装请填写 pgyer.password，并使用引号保留密码原样。'
      end
      data.merge('install_type' => type)
    end

    def upload(ipa, description)
      settings = validate!
      base = API
      fields = { '_api_key' => settings.fetch('api_key'), 'buildType' => 'ios', 'buildInstallType' => settings.fetch('install_type'),
                 'buildUpdateDescription' => description.to_s }
      fields['buildPassword'] = settings['password'] if settings['install_type'] == 2
      token = @http.json(:post, "#{base}/getCOSToken", fields: fields)
      check!(token)
      data = token.fetch('data')
      @http.upload(data.fetch('endpoint'), data.fetch('params'), ipa)
      interval, timeout = 3, 180
      deadline = @clock.call + timeout
      loop do
        result = @http.json(:get, "#{base}/buildInfo", fields: { '_api_key' => settings.fetch('api_key'), 'buildKey' => data.fetch('key') })
        if result['code'] == 1247
          remaining = deadline - @clock.call
          raise Error, '蒲公英仍在处理上传，请先在平台核对状态，避免重复上传。' if remaining <= 0
          @sleeper.call([interval, remaining].min)
          next
        end
        check!(result)
        published = result.fetch('data')
        key = published.fetch('buildKey')
        return { 'build_key' => key, 'url' => "https://www.pgyer.com/#{key}", 'qr_url' => published['buildQRCodeURL'] }
      end
    rescue KeyError, TypeError
      raise Error, '蒲公英返回缺少必要字段，无法确认发布成功。'
    end

    private

    def check!(result)
      raise Error, '蒲公英返回的结果格式无效。' unless result.is_a?(Hash)
      raise Error, "蒲公英发布失败（业务码 #{result['code']}）。" unless result['code'] == 0
    end
  end

  class AppStoreUpload
    def initialize(config, runner)
      @config, @runner = config, runner
    end

    def validate!
      apple = @config.require_values('appstore', 'key_id', 'issuer_id', 'key_file')
      raise Error, 'Apple Key ID 格式不正确。' unless apple['key_id'].to_s.match?(/\A[a-z0-9]+\z/i)
      @config.file(apple['key_file'], label: 'Apple 上传私钥')
    end

    def upload(ipa)
      validate!
      apple = @config.section('appstore')
      source = @config.file(apple['key_file'], label: 'Apple 上传私钥')
      help = @runner.run(['xcrun', 'altool', '--help'], label: '读取 Apple 上传工具', capture: true)
      if help.include?('--p8-file-path')
        auth = ['--api-key', apple['key_id'], '--api-issuer', apple['issuer_id'], '--p8-file-path', source, '--output-format', 'json']
        @runner.run(['xcrun', 'altool', '--validate-app', ipa, *auth], label: 'Apple 安装包校验')
        @runner.run(['xcrun', 'altool', '--upload-package', ipa, *auth], label: '上传 App Store Connect')
      else
        Dir.mktmpdir('jf-apple-key-') do |directory|
          destination = File.join(directory, "AuthKey_#{apple['key_id']}.p8")
          FileUtils.copy_file(source, destination)
          File.chmod(0o600, destination)
          auth = ['-f', ipa, '-t', 'ios', '--apiKey', apple['key_id'], '--apiIssuer', apple['issuer_id'], '--output-format', 'json']
          environment = { 'API_PRIVATE_KEYS_DIR' => directory }
          @runner.run(['xcrun', 'altool', '--validate-app', *auth], label: 'Apple 安装包校验', env: environment)
          @runner.run(['xcrun', 'altool', '--upload-app', *auth], label: '上传 App Store Connect', env: environment)
        end
      end
      { 'status' => 'uploaded', 'note' => '已完成上传，Apple 仍需处理构建；未提交审核或发布。' }
    end
  end

  class BuglyUpload
    BUNDLED_TOOL = File.expand_path('../../tools/buglyqq-upload-symbol.jar', __dir__).freeze
    LEGACY_TOOL = 'jfbuild/tools/buglyqq-upload-symbol.jar'.freeze
    SUCCESS = '(?i)(upload(?:ed)?[^\\n]*(?:success|succeed)|success(?:fully)?[^\\n]*upload|上传[^\\n]*成功)'.freeze
    FAILURE = '(?i)(upload[^\\n]*(?:failed|failure)|上传[^\\n]*失败|\\[.*(?:error|symtab-e).*\\])'.freeze

    def initialize(config, runner)
      @config, @runner = config, runner
    end

    def validate!
      data = @config.require_values('bugly', 'app_id', 'app_key')
      raise Error, 'bugly.tool_type 只能为 classic 或 pro。' unless %w[classic pro].include?(data.fetch('tool_type', 'classic'))
      tool_path
      @config.executable(data.fetch('java_path', 'java'), label: 'Java')
    end

    def upload(symbols, info)
      validate!
      raise Error, '未找到 dSYM，补传时请指定 --archive 或 --dsym。' unless symbols && File.exist?(symbols)
      data = @config.section('bugly')
      arguments = ['-appid', data['app_id'], '-appkey', data['app_key'], '-version', info.fetch('CFBundleShortVersionString'),
                   '-platform', 'IOS', '-inputSymbol', symbols]
      arguments += ['-bundleid', info.fetch('CFBundleIdentifier')] if data.fetch('tool_type', 'classic') == 'classic'
      command = [@config.executable(data.fetch('java_path', 'java'), label: 'Java'),
                 '-jar', tool_path, *arguments]
      result = @runner.run(command, label: '上传 Bugly 符号表', capture: true)
      raise Error, 'Bugly 工具报告上传失败，详情见日志。' if result.match?(Regexp.new(FAILURE))
      success = result.match?(Regexp.new(SUCCESS))
      responses = result.lines.map do |line|
        start = line.index('{')
        next unless start
        parsed = JSON.parse(line[start..-1]) rescue nil
        parsed if parsed.is_a?(Hash) && parsed.key?('statusCode')
      end.compact
      unless responses.empty?
        raise Error, 'Bugly 返回上传业务失败，详情见日志。' unless responses.last['statusCode'] == 0
        success ||= result.include?('/uploadFile')
      end
      raise Error, 'Bugly 未给出可确认的上传成功结果，请核对工具日志。' unless success
      { 'status' => 'uploaded' }
    end

    private

    def tool_path
      data = @config.section('bugly')
      path = data['tool_path'].to_s.strip
      if data.fetch('tool_type', 'classic') == 'classic'
        # 兼容旧模板的默认路径；已放置的工具和自定义路径优先。
        path = BUNDLED_TOOL if path.empty? || (path == LEGACY_TOOL && !File.exist?(@config.absolute(path)))
      elsif path.empty?
        raise Error, '请填写 bugly.tool_path，指定专业版符号表上传工具。'
      end
      @config.file(path, label: 'Bugly 官方符号表上传工具')
    end
  end

  class DingTalkNotify
    def initialize(config, http: nil)
      @config, @http = config, http || HTTP.new
    end

    def validate!
      data = @config.require_values('dingtalk', 'webhook')
      uri = URI(data['webhook'])
      raise Error, '请填写有效的 HTTPS Webhook。' unless uri.is_a?(URI::HTTPS) && uri.host && uri.userinfo.nil? && uri.fragment.nil?
    rescue URI::InvalidURIError
      raise Error, '钉钉 Webhook 格式不正确。'
    end

    def notify(message)
      validate!
      data = @config.section('dingtalk')
      uri = URI(data.fetch('webhook'))
      unless data['secret'].to_s.empty?
        timestamp = (Time.now.to_f * 1000).to_i.to_s
        sign = Base64.strict_encode64(OpenSSL::HMAC.digest('SHA256', data['secret'], "#{timestamp}\n#{data['secret']}"))
        uri.query = URI.encode_www_form(URI.decode_www_form(uri.query.to_s) + [['timestamp', timestamp], ['sign', sign]])
      end
      content = [data['keyword'], message].reject { |value| value.to_s.empty? }.join("\n")
      body = { 'msgtype' => 'text', 'text' => { 'content' => content } }
      result = @http.json(:post, uri.to_s, body: body)
      raise Error, "钉钉通知失败（业务码 #{result['errcode']}）。" unless result['errcode'] == 0
      { 'status' => 'sent' }
    end
  end
end
