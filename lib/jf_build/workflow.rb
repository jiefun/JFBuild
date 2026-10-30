module JFBuild
  class Workflow
    STEP_NAMES = Plan::LABELS.merge('check_archive' => '检查归档', 'check_ipa' => '检查 IPA').freeze
    STEP_ORDER = %w[archive check_archive export check_ipa pgyer appstore bugly dingtalk].freeze
    attr_reader :config, :output, :report, :runner

    def initialize(root, overrides: {}, runner: nil, services: {}, io: $stdout)
      @config = Config.new(root)
      @overrides, @injected_runner, @injected_services, @io = overrides, runner, services, io
      @console = Console.new(io)
      @catalog = Artifacts.new(config)
      @report = { 'tool_version' => VERSION, 'created_at' => Time.now.iso8601, 'steps' => {} }
    end

    def run(mode, archive: nil, ipa: nil, dsym: nil, description: '', archive_only: false, export_only: false)
      archive, ipa, dsym = [archive, ipa, dsym].map { |path| path && config.absolute(path) }
      config.activate_mode(mode)
      @catalog.with_lock do
        @record = @catalog.find(archive: archive, ipa: ipa)
        raise Error, '指定产物的包类型与当前流程不一致，请选择原流程或重新归档。' if @record && @record['mode'] != mode
        archive ||= @record['archive'] if @record
        settings = @record ? @record.slice('configuration', 'export_method') : config.mode(mode)
        @output = @record ? @record.fetch('directory') : @catalog.new_directory
        setup!
        @report.merge!('mode' => mode, 'configuration' => settings.fetch('configuration'), 'description' => description,
                       'source' => ipa ? 'ipa' : (archive ? 'archive' : 'new'))
        collect_build_info(new_build: @report['source'] == 'new')
        unless archive_only || export_only
          @plan = Plan.new(config, mode, overrides: @overrides, settings: settings).validate!(source: @report['source'].to_sym)
          @console.flow(@plan.steps(source: @report['source'].to_sym), prefix: '开始执行：', compact: true)
          @plan.states.each { |name, state| skip(name, state['reason']) if state['status'] == 'skipped' }
        end
        @build.export_options(mode) unless archive_only || ipa
        if !archive && !ipa
          # 通过前置检查后再清理旧归档。
          @build.resolve!
          @build.validate_signing!
          config.archive_hook(mode)
          @catalog.prune_before_new!.each { |path| @io.puts("已清理最旧打包记录：#{path}") }
          @record = @catalog.create(mode, settings, directory: output, description: @runner.redact(description),
                                    builder: @report['builder'])
        end
        info = nil
        begin
          unless ipa
            archive ||= required_step('archive') { @build.archive(mode, output) }
            info = inspect_archive(archive)
            remember_archive(archive, info)
            return finish! if archive_only
            @build.validate_signing!
            @build.install_signing! if @report.dig('steps', 'archive').nil?
            ipa = required_step('export') { @build.export(archive, mode, output, method: settings.fetch('export_method')) }
          end
          info = inspect_ipa(ipa, archive)
          @report['ipa'], @report['app'] = ipa, summarize(info)
          @report['archive'] = archive if archive
          if @record
            @record['ipa'] = ipa
            @catalog.save(@record)
          end
          unless export_only
            package = mode == 'appstore' ? 'appstore' : 'pgyer'
            optional_step(package) { upload_package(package, ipa, description) } if ready?(package)
          end
        rescue Error => error
          @report['failure'] = error.message
        end
        unless export_only
          package = mode == 'appstore' ? 'appstore' : 'pgyer'
          skip(package, '没有可用 IPA') if ready?(package) && !@report['steps'].key?(package)
          if ready?('bugly')
            symbols = dsym || (archive && File.join(archive, 'dSYMs'))
            if info && !@unsafe_artifact && symbols && File.exist?(symbols)
              optional_step('bugly') { @services['bugly'].upload(symbols, info) }
            else
              skip('bugly', '没有可用的对应 dSYM 或产物检查未通过')
            end
          end
          optional_step('dingtalk') { @services['dingtalk'].notify(notification) } if ready?('dingtalk')
        end
        finish!
      ensure
        persist!
      end
    end

    def upload_only(service, ipa: nil, archive: nil, dsym: nil, description: '')
      archive, ipa, dsym = [archive, ipa, dsym].map { |path| path && config.absolute(path) }
      @catalog.with_lock do
        @record = @catalog.find(archive: archive, ipa: ipa)
        @output = @record ? @record.fetch('directory') : @catalog.new_directory
        setup!
        @report.merge!('mode' => @record && @record['mode'], 'description' => description, 'source' => 'upload-only')
        collect_build_info
        @services.fetch(service).validate!
        case service
        when 'pgyer', 'appstore'
          raise Error, '请用 --ipa 指定已经导出的安装包。' unless ipa
          info = inspect_ipa(ipa, archive)
          @report['ipa'], @report['app'] = ipa, summarize(info)
          optional_step(service) { upload_package(service, ipa, description) }
        when 'bugly'
          if @record && !@record['configuration'].casecmp('Release').zero?
            raise Error, '该归档不是 Release 构建，不上传 Bugly。'
          end
          raise Error, '补传 Bugly 请提供 --archive，或同时提供 --ipa 和 --dsym。' unless archive || (ipa && dsym)
          info = ipa ? inspect_ipa(ipa, archive) : inspect_archive(archive)
          @report['archive'], @report['app'] = archive, summarize(info)
          optional_step(service) { @services[service].upload(dsym || File.join(archive, 'dSYMs'), info) }
        end
        finish!
      ensure
        persist!
      end
    end

    def notify(message)
      @catalog.with_lock do
        setup!
        @services['dingtalk'].validate!
        optional_step('dingtalk') { @services['dingtalk'].notify(message) }
        finish!
      ensure
        persist!
      end
    end

    def check(ipa)
      raise Error, '请用 --ipa 指定需要检查的安装包。' unless ipa
      setup!
      @console.progress('检查 IPA') { current_guard.check_ipa!(config.absolute(ipa)) }
      @io.puts('IPA 检查通过：未发现已知打包配置或上传私钥。')
    end

    private

    def setup!
      return if @runner
      @output ||= @catalog.new_directory
      @secrets = config.sensitive_values
      attempt = "#{Time.now.strftime('%Y%m%d-%H%M%S')}-#{SecureRandom.hex(3)}"
      @attempt = attempt
      @runner = @injected_runner || Runner.new(File.join(@output, 'logs', attempt), secrets: @secrets, console: @console)
      @build = Build.new(config, @runner)
      @services = {
        'pgyer' => PgyerUpload.new(config), 'appstore' => AppStoreUpload.new(config, @runner),
        'bugly' => BuglyUpload.new(config, @runner), 'dingtalk' => DingTalkNotify.new(config)
      }.merge(@injected_services)
    end

    def ready?(name)
      @plan && @plan.states[name] && @plan.states[name]['status'] == 'ready'
    end

    def current_guard
      BundleGuard.new(config.root, secrets: @secrets, protected_files: config.protected_files)
    end

    def inspect_archive(archive)
      info = nil
      required_step('check_archive') do
        app = @build.app_in_archive(archive)
        current_guard.check_app!(app)
        info = @build.app_info(app)
      end
      info
    rescue Error
      @unsafe_artifact = true
      raise
    end

    def inspect_ipa(ipa, archive)
      info = nil
      required_step('check_ipa') do
        current_guard.check_ipa!(ipa)
        info = BundleGuard.ipa_info(ipa)
        if archive
          archived = @build.app_info(@build.app_in_archive(archive))
          unless %w[CFBundleIdentifier CFBundleShortVersionString CFBundleVersion].all? { |key| archived[key].to_s == info[key].to_s }
            raise Error, '提供的归档与 IPA 包名、版本或构建号不同，不能混用符号表。'
          end
        end
      end
      info
    rescue Error
      @unsafe_artifact = true
      raise
    end

    def remember_archive(archive, info)
      @report['archive'], @report['app'] = archive, summarize(info)
      return unless @record
      @record['archive'] = archive
      @record['app_directory'] = File.basename(@build.app_in_archive(archive))
      @record['app'] = summarize(info)
      @catalog.save(@record)
    end

    def upload_package(service, ipa, description)
      @report['distribution_type'] = Distribution.validate!(ipa, service)
      service == 'pgyer' ? @services[service].upload(ipa, build_description(description)) : @services[service].upload(ipa)
    end

    def collect_build_info(new_build: false)
      if new_build
        name, status = Open3.capture2e('git', '-C', config.root, 'config', 'user.name')
        @report['builder'] = status.success? ? @runner.redact(name.encode('UTF-8', invalid: :replace, undef: :replace).gsub(/[[:cntrl:]]+/, ' ').strip) : nil
      else
        # 补传只使用原归档信息，不把上传者或当前配置当成打包信息。
        @report['builder'] = @record && @record['builder']
        @report['configuration'] = @record && @record['configuration']
      end
    rescue SystemCallError
      @report['builder'] = nil
    end

    def build_info_lines
      [['打包人', @report['builder']], ['构建类型', @report['configuration']]].map do |label, value|
        value = value.to_s.strip
        "#{label}：#{value}" unless value.empty?
      end.compact
    end

    def build_description(description)
      lines = build_info_lines
      return description.to_s if lines.empty?
      (lines + ['', '更新内容：', description.to_s]).join("\n")
    end

    def summarize(info)
      { 'name' => info['CFBundleDisplayName'] || info['CFBundleName'], 'bundle_id' => info['CFBundleIdentifier'],
        'version' => info['CFBundleShortVersionString'], 'build' => info['CFBundleVersion'] }
    end

    def required_step(name)
      value = @console.progress(STEP_NAMES.fetch(name, name)) { yield }
      @report['steps'][name] = { 'status' => 'success' }
      value
    rescue Error => error
      @report['steps'][name] = { 'status' => 'failed', 'error' => error.message }
      raise
    end

    def optional_step(name)
      value = @console.progress(STEP_NAMES.fetch(name, name)) { yield }
      @report['steps'][name] = { 'status' => 'success', 'result' => value }
    rescue Error => error
      @report['steps'][name] = { 'status' => 'failed', 'error' => error.message }
    end

    def skip(name, reason)
      @report['steps'][name] = { 'status' => 'skipped', 'reason' => reason }
    end

    def ordered_steps
      @report['steps'].sort_by { |name, _value| STEP_ORDER.index(name) || STEP_ORDER.length }
    end

    def result_entries
      ordered_steps.reject { |name, value| %w[check_archive check_ipa].include?(name) && value['status'] == 'success' }.map do |name, value|
        { 'label' => STEP_NAMES.fetch(name, name), 'status' => value['status'], 'reason' => value['reason'] || value['error'] }
      end
    end

    def notification
      app = @report['app'] || {}
      lines = ["#{app['name'] || 'iOS App'} #{app['version']} (#{app['build']})", "包类型：#{Plan::MODES[@report['mode']]}"]
      lines.concat(build_info_lines)
      description = @report['description'].to_s
      lines << "更新内容：\n#{description}" unless description.strip.empty?
      ordered_steps.each do |name, value|
        status = { 'success' => '成功', 'failed' => '失败', 'skipped' => '跳过' }.fetch(value['status'])
        lines << "#{STEP_NAMES.fetch(name, name)}：#{status}"
      end
      lines << @report['failure'] if @report['failure']
      link = @report.dig('steps', 'pgyer', 'result', 'url')
      lines << "下载地址：#{link}" if link
      @runner.redact(lines.compact.join("\n"))
    end

    def safe_report(value)
      case value
      when Hash then value.to_h { |key, item| [key, safe_report(item)] }
      when Array then value.map { |item| safe_report(item) }
      when String then @runner.redact(value)
      else value
      end
    end

    def persist!
      return unless @output && @runner
      FileUtils.mkdir_p(File.join(output, 'results'))
      @report['steps'] = ordered_steps.to_h
      content = JSON.pretty_generate(safe_report(@report)) + "\n"
      [File.join(output, 'result.json'), File.join(output, 'results', "#{@attempt}.json")].each do |path|
        File.write(path, content, mode: 'w', perm: 0o600)
      end
    end

    def finish!
      persist!
      @console.flow(result_entries, prefix: '执行结果：')
      @io.puts("归档位置：#{@report['archive']}") if @report['archive']
      @io.puts("IPA 位置：#{@report['ipa']}") if @report['ipa']
      path = File.join(output, 'result.json')
      @io.puts("结果已保存：#{path}")
      link = @report.dig('steps', 'pgyer', 'result', 'url')
      @io.puts("蒲公英下载地址：#{link}") if link
      raise Error, "部分步骤失败，已有产物保留。请查看 #{path}。" if @report['failure'] || @report['steps'].values.any? { |value| value['status'] == 'failed' }
      @report
    end
  end
end
