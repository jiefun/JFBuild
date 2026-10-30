require 'digest'
require 'find'
require 'tmpdir'

module JFBuild
  class BundleGuard
    PRIVATE_KEY = /-----BEGIN ((?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY)-----\r?\n(?:(?:Proc-Type|DEK-Info):[^\r\n]*\r?\n)*\r?\n?[A-Za-z0-9+\/=\r\n]{64,}-----END \1-----/n
    PRIVATE_KEY_OVERLAP = 64 * 1024

    def initialize(root, secrets: [], protected_files: [])
      @root = File.expand_path(root)
      @secrets = secrets.select { |value| value.to_s.bytesize >= 8 }.map { |value| value.to_s.b }
      @hashes = protected_files.select { |path| File.file?(path) && !File.zero?(path) && File.extname(path) != '.mobileprovision' }
                               .map { |path| Digest::SHA256.file(path).hexdigest }
      directory = File.join(@root, Config::DIRECTORY)
      if File.directory?(directory)
        Find.find(directory) do |path|
          next unless File.file?(path)
          next if File.zero?(path)
          next if File.extname(path) == '.mobileprovision'
          @hashes << Digest::SHA256.file(path).hexdigest
        end
      end
    end

    def check_app!(app)
      raise Error, '未找到归档中的 App。' unless File.directory?(app)
      scan_directory!(app)
    end

    def scan_directory!(app)
      Find.find(app) do |path|
        relative = Pathname(path).relative_path_from(Pathname(app)).to_s
        reject_path!(relative)
        next unless File.file?(path)
        File.open(path, 'rb') { |stream| check_stream!(stream, relative) }
      end
      true
    end

    def check_ipa!(ipa)
      raise Error, '未找到 IPA 文件。' unless File.file?(ipa)
      Dir.mktmpdir('jfbuild-scan-') do |directory|
        Native.call('extract-ipa', ipa, directory)
        scan_directory!(directory)
      end
      true
    end

    def self.ipa_info(ipa)
      info = Native.call('ipa-info', ipa)
      unless info.is_a?(Hash) && %w[CFBundleIdentifier CFBundleShortVersionString CFBundleVersion].all? { |key| !info[key].to_s.empty? }
        raise Error, 'IPA 的 Info.plist 缺少包名、版本号或构建号。'
      end
      info
    rescue Error
      raise
    rescue StandardError
      raise Error, '无法读取 IPA 中的 Info.plist。'
    end

    private

    def reject_path!(path)
      components = path.tr('\\', '/').split('/')
      if path.start_with?('/') || components.include?('..') || components.include?('jfbuild') || path.match?(/\.(?:p8|p12|pfx)\z/i)
        raise Error, "成品包含打包目录或私钥文件：#{path}，已停止后续操作。"
      end
    end

    def check_stream!(stream, name)
      digest = Digest::SHA256.new
      tail = ''.b
      # 加密库可能含有 PEM 标识常量，只有完整的私钥数据块才视为私钥内容。
      overlap = [@secrets.map(&:bytesize).max || 0, PRIVATE_KEY_OVERLAP].max
      while (chunk = stream.read(1024 * 1024)) && !chunk.empty?
        chunk = chunk.b
        digest.update(chunk)
        window = tail + chunk
        if window.match?(PRIVATE_KEY)
          raise Error, "成品包含完整私钥内容：#{name}，已停止后续操作。"
        end
        if @secrets.any? { |secret| window.include?(secret) }
          raise Error, "成品包含已配置的打包上传凭证：#{name}，已停止后续操作。"
        end
        tail = window.byteslice(-overlap, overlap) || window
      end
      # 描述文件是 Apple 正常签名产物的一部分，不作为凭证泄漏处理。
      return if File.basename(name) == 'embedded.mobileprovision'
      raise Error, "成品包含打包专用配置或凭证文件：#{name}，已停止后续操作。" if @hashes.include?(digest.hexdigest)
    end
  end
end
