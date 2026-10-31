require 'optparse'

module JFBuild
  class CLI
    def initialize(argv, input: $stdin, output: $stdout, error: $stderr)
      @argv, @input, @output, @error = argv.dup, input, output, error
      @console = Console.new(output, input)
      @options = { root: Dir.pwd, description: '' }
      @overrides = {}
    end

    def run
      parser.parse!(@argv)
      action = @argv.shift
      if action == 'config'
        raise Error, '配置更新命令：./jbuild config update' unless @argv.shift == 'update'
      end
      actions = %w[init config dev release appstore archive export upload-pgyer upload-appstore upload-bugly notify check]
      raise Error, @parser.to_s unless (action.nil? || actions.include?(action)) && @argv.empty?
      root = File.realpath(@options[:root])
      existing = File.file?(File.join(root, Config::DIRECTORY, 'config.yml'))
      Config.bootstrap(root)
      if action == 'init' || !existing
        skill = Config.install_skill(root)
        begin
          choices = Config.new(root).autofill!
          @console.line("已自动填写：#{choices.keys.join('、')}") unless choices.empty?
        rescue Error => error
          @console.line(error.message, 'skipped')
        end
        @console.line("#{existing ? '保留已有配置' : '已生成配置'}：#{root}/jfbuild/config.yml")
        @console.line("Skill 入口：#{skill}")
        @console.line('请编辑 jfbuild/config.yml 后运行 ./jbuild。')
        return %w[init config].include?(action) ? 0 : 2
      end
      @config = Config.new(root)
      return update_config if action == 'config'
      @config.warnings.each { |message| @console.line(message, 'skipped') }
      @config.resolved_data # 先检查旧格式是否需要显式更新，再展示菜单。
      action = choose_action if action.nil?
      return 0 unless action
      action = choose_record if action == 'continue'
      return 0 unless action
      return run_utility(action) unless Plan::MODES.key?(action)
      store = Artifacts.new(@config)
      record = store.find(archive: absolute(@options[:archive]), ipa: absolute(@options[:ipa]))
      settings = record && record.slice('configuration', 'export_method')
      raise Error, '指定产物原来的包类型与本次流程不一致，请选择原流程或重新归档。' if record && record['mode'] != action
      plan = Plan.new(@config, action, overrides: @overrides, settings: settings)
      source = @options[:ipa] ? :ipa : (@options[:archive] ? :archive : :new)
      entries = plan.steps(source: source)
      @console.option("本次#{Plan::MODES.fetch(action)}", entries)
      @console.details(entries)
      plan.validate!(source: source)
      @options[:description] = @console.description(@options[:description]) unless action == 'appstore'
      Workflow.new(root, overrides: @overrides, io: @output).run(action, archive: @options[:archive], ipa: @options[:ipa],
        dsym: @options[:dsym], description: @options[:description])
      0
    rescue Error, OptionParser::ParseError, Errno::ENOENT, SystemCallError => error
      @error.puts(@console.paint(error.message, 'error'))
      @error.puts
      1
    rescue Interrupt
      @error.puts('已取消。')
      130
    end

    private

    def parser
      @parser = OptionParser.new do |args|
        args.banner = '用法：jbuild；快捷指令：jbuild dev／release／appstore'
        args.separator '输入 1–4 选择操作；可用 --desc 传入更新内容。'
        args.separator '初始化：jbuild init；配置更新：jbuild config update'
        args.separator '高级命令：archive、export、upload-pgyer、upload-appstore、upload-bugly、notify、check'
        args.on('--root=路径', 'App 项目目录') { |value| @options[:root] = value }
        args.on('--mode=模式', '高级归档／导出命令使用的包类型') { |value| @options[:mode] = value }
        args.on('--desc=说明', '提前传入更新内容，避免开始前询问') { |value| @options[:description] = value }
        %w[archive ipa dsym].each { |name| args.on("--#{name}=路径") { |value| @options[name.to_sym] = value } }
        Config::SERVICES.each { |name| args.on("--[no-]#{name}") { |value| @overrides[name] = value } }
        args.on('-v', '--version') { @output.puts(VERSION); throw :cli_exit, 0 }
        args.on('-h', '--help') { @output.puts(args); throw :cli_exit, 0 }
      end
    end

    def choose_action
      @console.line('请选择操作，输入序号（0 退出）：')
      @console.line('')
      Plan::MODES.each_with_index do |(mode, label), index|
        @console.option("#{index + 1}. #{label}", Plan.new(@config, mode, overrides: @overrides).steps)
      end
      @console.line('4. 使用已有归档继续', 'title')
      @console.line('   选择归档 → 选择从导出或上传开始')
      @console.line('')
      choice = @console.choose('请输入序号：', %w[1 2 3 4])
      { '1' => 'dev', '2' => 'release', '3' => 'appstore', '4' => 'continue' }[choice]
    end

    def choose_record
      store = Artifacts.new(@config)
      records = store.archives
      raise Error, '没有可用的历史归档' if records.empty?
      records.each_with_index do |record, index|
        app = record.fetch('app', {})
        created_at = record.fetch('time').getlocal.strftime('%Y-%m-%d %H:%M:%S')
        @console.line("#{index + 1}. #{Plan::MODES.fetch(record['mode'])} | #{app['name']} #{app['version']}(#{app['build']}) | #{record['configuration']} | #{created_at}")
        description = record['description'].to_s.gsub(/[[:cntrl:]]+/, ' ').strip
        @console.line("   更新内容：#{description.empty? ? '未记录' : description}")
        @console.line('')
      end
      choice = @console.choose('请选择归档序号（0 退出）：', (1..records.length).map(&:to_s))
      return nil unless choice
      record = records.fetch(choice.to_i - 1)
      @console.line("已选择归档：#{record.fetch('archive')}")
      plan = Plan.new(@config, record.fetch('mode'), overrides: @overrides, settings: record.slice('configuration', 'export_method'))
      @console.option('1. 从导出开始', plan.steps(source: :archive))
      ipa_available = store.valid_path?(record, record['ipa'])
      if ipa_available
        @console.line("IPA：#{record['ipa']}")
        @console.option('2. 使用已有 IPA 直接上传', plan.steps(source: :ipa))
      else
        @console.line('2. 使用已有 IPA（该记录没有可用 IPA，无法选择）', 'error')
      end
      start = @console.choose('请选择继续方式（0 退出）：', ipa_available ? %w[1 2] : ['1'])
      return nil unless start
      @options[:archive] = record.fetch('archive')
      @options[:ipa] = record.fetch('ipa') if start == '2'
      record.fetch('mode')
    end

    def update_config
      result = @config.update!
      if result['changed']
        @console.line("配置已更新，已填写的值保留。原文件备份：#{result['backup']}")
        @console.line("新增字段：#{result['added'].join('、')}") unless result['added'].empty?
        @console.line('请检查更新后的配置。')
      else
        @console.line('配置已是当前格式，无需更新。')
      end
      @console.line("保留的未知字段：#{result['unused'].join('、')}", 'skipped') unless result['unused'].empty?
      0
    end

    def run_utility(action)
      workflow = Workflow.new(@config.root, overrides: @overrides, io: @output)
      case action
      when 'check' then workflow.check(@options[:ipa])
      when 'notify'
        raise Error, '请用 --desc 提供通知内容。' if @options[:description].empty?
        workflow.notify(@options[:description])
      when /^upload-(.+)$/
        service = Regexp.last_match(1)
        @options[:description] = @console.description(@options[:description]) if service == 'pgyer'
        workflow.upload_only(service, ipa: @options[:ipa], archive: @options[:archive], dsym: @options[:dsym], description: @options[:description])
      when 'archive', 'export'
        raise Error, 'export 需要 --archive。' if action == 'export' && !@options[:archive]
        workflow.run(@options[:mode] || 'release', archive: @options[:archive], ipa: @options[:ipa],
          description: @options[:description], archive_only: action == 'archive', export_only: action == 'export')
      end
      0
    end

    def absolute(path)
      path && @config.absolute(path)
    end
  end
end
