module JFBuild
  class Plan
    MODES = { 'dev' => '开发包', 'release' => '正式验收包', 'appstore' => 'App Store 包' }.freeze
    LABELS = { 'archive' => '归档', 'export' => '导出 IPA', 'pgyer' => '上传蒲公英',
               'appstore' => '上传 App Store', 'bugly' => '上传 Bugly', 'dingtalk' => '钉钉通知' }.freeze
    REQUIRED = {
      'pgyer' => { 'api_key' => 'API Key' },
      'appstore' => { 'key_id' => 'Key ID', 'issuer_id' => 'Issuer ID', 'key_file' => 'P8 授权文件' },
      'bugly' => { 'app_id' => 'App ID', 'app_key' => 'App Key', 'tool_path' => '符号表上传工具路径' },
      'dingtalk' => { 'webhook' => 'Webhook' }
    }.freeze
    attr_reader :mode, :configuration, :export_method, :states

    def initialize(config, mode, overrides: {}, settings: nil)
      @config, @mode, @overrides = config, mode, overrides
      settings ||= config.section('modes')[mode]
      settings = {} unless settings.is_a?(Hash)
      @configuration, @export_method = settings['configuration'].to_s, settings['export_method'].to_s
      @states = {}
      service_names.each { |name| @states[name] = inspect_service(name) }
    end

    def service_names
      [mode == 'appstore' ? 'appstore' : 'pgyer', *(@configuration.casecmp('Release').zero? ? ['bugly'] : []), 'dingtalk']
    end

    def steps(source: :new)
      entries = []
      archive_problem = source == :new ? project_issue : nil
      archive_status = source == :new ? (archive_problem ? 'error' : 'ready') : 'skipped'
      entries << entry('archive', archive_status, source == :new ? archive_problem : '复用指定归档')
      label = { 'dev' => '导出开发 IPA', 'release' => '导出验收 IPA', 'appstore' => '导出商店 IPA' }.fetch(mode)
      export_problem = source == :ipa ? nil : (export_issue || (archive_problem && '需先填写归档所需配置'))
      export_status = source == :ipa ? 'skipped' : (export_problem ? 'error' : 'ready')
      entries << entry('export', export_status, source == :ipa ? '复用指定 IPA' : export_problem).merge('label' => label)
      entries + service_names.map { |name| states.fetch(name) }
    end

    def validate!(source: :new)
      issue = export_method_issue
      raise Error, issue if issue
      failed = steps(source: source).find { |state| state['status'] == 'error' }
      raise Error, "#{failed['label']}：#{failed['reason']}，此流程无法开始。" if failed
      self
    end

    private

    def export_issue
      missing = []
      missing << "modes.#{mode}.export_method" if export_method.strip.empty?
      signing = @config.section('signing')
      if signing['style'] == 'manual'
        profiles = signing['provisioning_profiles']
        profiles = profiles[mode] if profiles.is_a?(Hash)
        if profiles.nil? || (profiles.respond_to?(:empty?) && profiles.empty?)
          missing << "signing.provisioning_profiles.#{mode}"
        end
      end
      missing.empty? ? nil : "未配置 #{missing.join('、')}"
    end

    def export_method_issue
      store = %w[app-store app-store-connect].include?(export_method)
      return 'App Store 包必须配置商店导出方式。' if mode == 'appstore' && !store
      return '开发包和正式验收包不能配置商店导出方式。' if mode != 'appstore' && store
      nil
    end

    def project_issue
      workspace, project = @config.value('workspace').to_s, @config.value('project').to_s
      missing = []
      missing << 'workspace 或 project' if workspace.strip.empty? && project.strip.empty?
      missing << 'scheme' if @config.value('scheme').to_s.strip.empty?
      missing << "modes.#{mode}.configuration" if configuration.strip.empty?
      missing.empty? ? nil : "未配置 #{missing.join('、')}"
    end

    def entry(name, status, reason = nil)
      { 'name' => name, 'label' => LABELS.fetch(name), 'status' => status, 'reason' => reason }
    end

    def inspect_service(name)
      mandatory = name == 'appstore'
      if @overrides[name] == false
        return entry(name, mandatory ? 'error' : 'skipped', mandatory ? '此流程必须上传 App Store' : '本次指定跳过')
      end
      data = @config.section(name)
      missing = REQUIRED.fetch(name).select { |key, _label| data[key].to_s.strip.empty? }.values
      if name == 'pgyer' && data.fetch('install_type', 2).to_s == '2' && !data['api_key'].to_s.empty? && data['password'].to_s.empty?
        missing << '安装密码'
      end
      return entry(name, mandatory ? 'error' : 'skipped', "未配置 #{missing.join('、')}") unless missing.empty?
      entry(name, 'ready')
    rescue Error => error
      entry(name, mandatory ? 'error' : 'skipped', error.message)
    end
  end
end
