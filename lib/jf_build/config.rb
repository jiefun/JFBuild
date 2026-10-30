require 'yaml'
require 'json'
require 'pathname'
require 'fileutils'
require 'tempfile'
require 'uri'
require 'securerandom'

module JFBuild
  class Config
    DIRECTORY = 'jfbuild'.freeze
    MATERIAL_DIRECTORIES = %w[signing keys tools].freeze
    TEMPLATE = File.expand_path('../../templates/config.yml', __dir__)
    LAUNCHER_TEMPLATE = File.expand_path('../../templates/jbuild', __dir__)
    LEGACY_LAUNCHER = <<~'SH'.freeze
      #!/bin/sh
      project_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
      if [ ! -f "$project_root/Pods/JFBuild/jbuild" ]; then
        echo "尚未安装 JFBuild，请先在项目目录执行 pod install。" >&2
        exit 1
      fi
      exec "$project_root/Pods/JFBuild/jbuild" --root="$project_root" "$@"
    SH
    SERVICES = %w[pgyer appstore bugly dingtalk].freeze
    CONFIG_VERSION = 2
    # 配置格式按版本逐级迁移。
    MIGRATIONS = {
      0 => ->(data) { data.merge('config_version' => 1) },
      1 => lambda do |data|
        data.delete('default_mode')
        SERVICES.each { |name| data[name].delete('enabled') if data[name].is_a?(Hash) }
        data.merge('config_version' => 2)
      end
    }.freeze
    EXTRA_FIELDS = %w[signing.certificate signing.keychain].freeze
    attr_reader :root, :path, :data, :active_mode

    def self.bootstrap(root)
      root = File.realpath(root)
      directory = File.join(root, DIRECTORY)
      FileUtils.mkdir_p(directory)
      raise Error, 'jfbuild 目录不能通过软链接指向项目外。' unless inside?(File.realpath(directory), root)
      MATERIAL_DIRECTORIES.each do |name|
        materials = File.join(directory, name)
        FileUtils.mkdir_p(materials)
        raise Error, "jfbuild/#{name} 目录不能通过软链接指向项目外。" unless inside?(File.realpath(materials), root)
        begin
          File.open(File.join(materials, '.gitkeep'), File::WRONLY | File::CREAT | File::EXCL, 0o644) {}
        rescue Errno::EEXIST
        end
      end
      begin
        File.open(File.join(directory, 'config.yml'), File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(File.read(TEMPLATE)) }
      rescue Errno::EEXIST
      end
      launcher = File.join(root, 'jbuild')
      begin
        File.open(launcher, File::WRONLY | File::CREAT | File::EXCL, 0o755) do |file|
          file.write(File.read(LAUNCHER_TEMPLATE))
        end
      rescue Errno::EEXIST
        if !File.symlink?(launcher) && File.file?(launcher) && File.read(launcher) == LEGACY_LAUNCHER
          Tempfile.create(['.jbuild-', '.rb'], root) do |file|
            file.chmod(0o755)
            file.write(File.read(LAUNCHER_TEMPLATE))
            file.close
            File.rename(file.path, launcher)
          end
        end
      end
      directory
    end

    def initialize(root)
      @root = File.realpath(root)
      self.class.bootstrap(@root)
      @path = File.join(@root, DIRECTORY, 'config.yml')
      raise Error, '打包配置不能通过软链接指向项目外。' unless self.class.inside?(File.realpath(@path), @root)
      @data = load_yaml(@path)
      @defaults = load_yaml(TEMPLATE)
      validate_version!
    end

    def config_version
      @data.fetch('config_version', 0)
    end

    def warnings
      messages = []
      messages << "配置格式为 #{config_version}，当前支持 #{CONFIG_VERSION}；可执行 ./jbuild config update 更新。" if config_version < CONFIG_VERSION
      fields = unknown_fields(@defaults, @data)
      messages << "配置中有已停用或无法识别的字段：#{fields.join('、')}；原内容保留，请对照新版模板检查拼写或迁移说明。" unless fields.empty?
      messages
    end

    def update!
      original = File.read(@path)
      # 以磁盘当前内容作为更新基线。
      @data = load_yaml(@path)
      validate_version!
      upgraded = migrated_data(allow_behavior_change: true)
      added = missing_fields(@defaults, upgraded)
      merged = deep_merge(@defaults, upgraded)
      return { 'changed' => false, 'added' => [], 'unused' => unknown_fields(@defaults, merged) } if merged == @data
      raise Error, '配置正在被编辑，请保存后重新执行更新。' unless File.read(@path) == original
      backup = "#{@path}.bak-#{Time.now.strftime('%Y%m%d-%H%M%S')}-#{SecureRandom.hex(3)}"
      File.open(backup, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(original) }
      atomic_write("# JFBuild 项目配置\n" + YAML.dump(merged))
      @data = merged
      { 'changed' => true, 'backup' => backup, 'added' => added, 'unused' => unknown_fields(@defaults, merged) }
    end

    def resolved_data
      deep_merge(@defaults, migrated_data)
    end

    def activate_mode(name)
      mode(name)
      @active_mode = name
      self
    end

    def value(name)
      resolved_data[name]
    end

    def archive_limit
      value = resolved_data.fetch('keep_archives', 2)
      raise Error, 'keep_archives 必须是大于 0 的整数。' unless value.is_a?(Integer) && value > 0
      value
    end

    def section(name)
      value = resolved_data[name] || {}
      raise Error, "#{name} 必须是配置对象。" unless value.is_a?(Hash)
      value
    end

    def mode(name)
      raise Error, '打包模式请选择 dev、release 或 appstore。' unless %w[dev release appstore].include?(name)
      value = section('modes')[name]
      raise Error, "未配置打包模式 #{name}。" unless value.is_a?(Hash)
      %w[configuration export_method].each do |key|
        raise Error, "请填写 modes.#{name}.#{key}。" unless value[key].is_a?(String) && !value[key].strip.empty?
      end
      value
    end

    def boolean(value, label)
      return value if [true, false].include?(value)
      return false if value.nil?
      return value == 'true' if %w[true false].include?(value)
      raise Error, "#{label} 必须为 true 或 false。"
    end

    def absolute(value)
      File.expand_path(value.to_s, @root)
    end

    def file(value, label: '文件')
      raise Error, "请填写#{label}路径。" if value.to_s.empty?
      path = absolute(value)
      raise Error, "未找到可读取的#{label}，请检查配置路径。" unless File.file?(path) && File.readable?(path)
      File.realpath(path)
    end

    def executable(value, label: '工具')
      value = value.to_s
      raise Error, "请填写#{label}。" if value.empty?
      if value.include?(File::SEPARATOR)
        path = absolute(value)
        raise Error, "#{label}路径不存在或不可执行。" unless File.file?(path) && File.executable?(path)
        path
      else
        value
      end
    end

    def self.inside?(path, parent)
      path == parent || path.start_with?(parent + File::SEPARATOR)
    end

    def require_values(name, *keys)
      value = section(name)
      missing = keys.select { |key| value[key].to_s.empty? }
      raise Error, "请填写 #{name} 的 #{missing.join('、')}。" unless missing.empty?
      value
    end

    def save!
      atomic_write(YAML.dump(@data))
    end

    def autofill!
      original = File.read(@path)
      @data = load_yaml(@path)
      workspace, project = @data['workspace'].to_s, @data['project'].to_s
      return {} unless workspace.strip.empty? || project.strip.empty?
      selected = workspace.strip.empty? ? project : workspace
      selected = '' if selected.strip.empty?
      detected = Native.call('project-options', root, selected)
      candidates = { 'workspace' => [], 'project' => [], 'scheme' => detected.fetch('scheme') }
      if selected.strip.empty?
        key = detected.fetch('workspace').empty? ? 'project' : 'workspace'
        candidates[key] = detected.fetch(key)
      end
      choices = {}
      content = original
      candidates.each do |key, values|
        next unless @data[key].to_s.strip.empty?
        content = content.gsub(/^# #{key} 可选值：\n(?:#   - [^\n]*\n)*/, '')
        pattern = /^#{key}:[^\n]*(?:\n|\z)/
        current = content.match(pattern)
        line = current ? current[0] : "#{key}:\n"
        if values.length == 1 && (key != 'scheme' || !detected.fetch('selected').empty?)
          choices[key] = values.first
          comment = line[/#[^\n]*/]
          line = "#{key}: #{JSON.generate(values.first)}#{comment ? ' ' + comment : ''}\n"
        elsif !values.empty?
          line = "# #{key} 可选值：\n" + values.map { |value| "#   - #{JSON.generate(value)}\n" }.join + line
        end
        content = current ? content.sub(pattern) { line } : content.sub(/\n?\z/) { "\n#{line}" }
      end
      if content != original
        raise Error, '配置正在被编辑，请保存后重新执行 init。' unless File.read(@path) == original
        atomic_write(content)
        @data = load_yaml(@path)
      end
      choices
    end

    def save_choices!(choices)
      content = File.read(@path)
      choices.each do |key, value|
        next if @data[key] == value
        raise Error, '只能保存工程和 Scheme 选择。' unless %w[workspace project scheme].include?(key)
        line = "#{key}: #{JSON.generate(value)}\n"
        pattern = /^#{Regexp.escape(key)}:[^\n]*(?:\n|\z)/
        content = content.match?(pattern) ? content.gsub(pattern) { line } : content.sub(/\n?\z/) { "\n#{line}" }
        @data[key] = value
      end
      atomic_write(content) unless content == File.read(@path)
    end

    def sensitive_values
      values = []
      walk = lambda do |node|
        case node
        when Hash
          node.each do |key, value|
            values << value.to_s if key.to_s.match?(/password|app_key|api_key|secret|webhook/) && !value.nil?
            if key.to_s == 'webhook' && value.is_a?(String)
              begin
                URI.decode_www_form(URI(value).query.to_s).each { |name, item| values << item if %w[access_token sign].include?(name) }
              rescue URI::InvalidURIError, ArgumentError
                # 忽略无效 URL，继续收集其他凭证。
              end
            end
            walk.call(value)
          end
        when Array then node.each { |item| walk.call(item) }
        end
      end
      walk.call(resolved_data)
      values.reject(&:empty?).flat_map { |value| [value, URI.encode_www_form_component(value)] }.uniq
    rescue URI::InvalidURIError, ArgumentError
      values.reject(&:empty?).uniq
    end

    def protected_files
      files = [@path]
      walk = lambda do |node|
        case node
        when Hash
          node.each do |key, value|
            if %w[p12 path key_file tool_path].include?(key.to_s) && value.is_a?(String) && !value.empty?
              files << absolute(value)
            elsif key.to_s == 'profiles' && value.is_a?(Array)
              files.concat(value.select { |item| item.is_a?(String) }.map { |item| absolute(item) })
            end
            walk.call(value)
          end
        when Array then node.each { |item| walk.call(item) }
        end
      end
      walk.call(resolved_data)
      files.select { |path| File.file?(path) && File.readable?(path) }.uniq
    end

    private

    def migrated_data(allow_behavior_change: false)
      value = @data
      legacy_switches = SERVICES.any? { |name| value[name].is_a?(Hash) && value[name].key?('enabled') }
      if config_version < 2 && legacy_switches && !allow_behavior_change
        raise Error, '新版按完整配置自动执行上传／通知，不再使用 enabled 开关；请先执行 ./jbuild config update 并检查配置差异。原文件未修改。'
      end
      while value.fetch('config_version', 0) < CONFIG_VERSION
        version = value.fetch('config_version', 0)
        migration = MIGRATIONS[version]
        raise Error, '此配置不能自动转换，请按更新说明处理；原文件未修改。' unless migration
        # 在副本上执行迁移。
        value = migration.call(Marshal.load(Marshal.dump(value)))
        unless value.is_a?(Hash) && value['config_version'] == version + 1
          raise Error, '配置转换版本不正确，原文件未修改。'
        end
      end
      value
    end

    def validate_version!
      version = config_version
      raise Error, 'config_version 必须是非负整数。' unless version.is_a?(Integer) && version >= 0
      return unless version > CONFIG_VERSION
      raise Error, "配置版本 #{version} 高于当前工具支持的 #{CONFIG_VERSION}；请同步团队 Podfile.lock 并执行 pod install，或升级 JFBuild。原配置未修改。"
    end

    def missing_fields(template, data, prefix = '')
      template.flat_map do |key, value|
        path = prefix.empty? ? key : "#{prefix}.#{key}"
        if !data.key?(key)
          [path]
        elsif value.is_a?(Hash) && data[key].is_a?(Hash)
          missing_fields(value, data[key], path)
        else
          []
        end
      end
    end

    def unknown_fields(template, data, prefix = '')
      data.flat_map do |key, value|
        path = prefix.empty? ? key.to_s : "#{prefix}.#{key}"
        if !template.key?(key)
          EXTRA_FIELDS.include?(path) ? [] : [path]
        elsif value.is_a?(Hash) && template[key].is_a?(Hash) && !template[key].empty?
          unknown_fields(template[key], value, path)
        else
          []
        end
      end
    end

    def load_yaml(path)
      value = YAML.safe_load(File.read(path), permitted_classes: [], permitted_symbols: [], aliases: false)
      raise Error, '打包配置必须是 YAML 对象。' unless value.is_a?(Hash)
      value
    rescue Psych::Exception
      raise Error, '打包配置格式不正确，请检查 YAML 缩进和引号。'
    end

    def deep_merge(left, right)
      left.merge(right) { |_key, old, current| old.is_a?(Hash) && current.is_a?(Hash) ? deep_merge(old, current) : current }
    end

    def atomic_write(content)
      Tempfile.create(['config', '.yml'], File.dirname(@path)) do |file|
        file.chmod(0o600)
        file.write(content)
        file.close
        File.rename(file.path, @path)
      end
    end
  end
end
