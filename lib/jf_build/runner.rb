require 'open3'

module JFBuild
  class Runner
    attr_reader :log_directory

    def initialize(log_directory, secrets: [], console: nil)
      @log_directory = log_directory
      FileUtils.mkdir_p(log_directory)
      @secrets = secrets.map(&:to_s).reject(&:empty?).sort_by { |value| -value.length }
      @index = 0
      @console = console
    end

    def redact(text)
      @secrets.reduce(text.to_s) { |value, secret| value.gsub(secret, '[已隐藏]') }
    end

    def run(arguments, label:, **options)
      operation = ->(progress) { run_command(arguments, label: label, progress: progress, **options) }
      @console ? @console.progress(label, &operation) : operation.call(nil)
    end

    private

    def run_command(arguments, label:, chdir: nil, env: {}, capture: false, acceptable_failure: nil, progress: nil)
      @index += 1
      name = label.to_s.gsub(/[^\p{L}\p{N}_-]+/, '')
      name = '命令' if name.empty?
      log = File.join(@log_directory, format('%02d_%s.log', @index, name))
      collected = +''
      status = nil
      options = chdir ? { chdir: chdir } : {}
      File.open(log, 'w', 0o600) do |file|
        private_block = false
        Open3.popen2e(env, *arguments.map(&:to_s), **options) do |stdin, output, wait|
          stdin.close
          output.each_line do |line|
            collected << line if capture || acceptable_failure
            detail = activity(line)
            progress.call(detail) if progress && detail
            private_block = true if line.match?(/-----BEGIN .*PRIVATE KEY-----/)
            file.write(private_block ? "[私钥内容已隐藏]\n" : redact(line))
            private_block = false if line.match?(/-----END .*PRIVATE KEY-----/)
          end
          status = wait.value
        end
      end
      unless status.success? || (acceptable_failure && collected.match?(acceptable_failure))
        raise Error, "#{label}失败，详情见 #{log}。"
      end
      collected
    rescue Errno::ENOENT
      raise Error, "#{label}所需命令未安装或路径无效。"
    end

    def activity(line)
      case line.lstrip
      when /\A(?:SwiftCompile|SwiftEmitModule|SwiftDriver|CompileSwift)/ then '编译 Swift'
      when /\ACompileC\b/ then '编译 Objective-C / C++'
      when /\A(?:CompileAssetCatalog|CompileStoryboard|CompileXIB|CopyStringsFile)/ then '处理资源'
      when /\A(?:Ld|Libtool)\b/ then '链接'
      when /\AProcessInfoPlistFile\b/ then '处理应用信息'
      when /\AProcessProductPackaging\b/ then '处理签名信息'
      when /\ACodeSign\b/ then '应用签名'
      when /\AValidate\b/ then '校验产物'
      end
    end
  end
end
