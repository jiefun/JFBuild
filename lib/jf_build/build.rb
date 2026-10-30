require 'time'
require 'securerandom'

module JFBuild
  class Build
    MODES = %w[dev release appstore].freeze
    METHOD_ALIASES = { 'debugging' => 'development', 'release-testing' => 'ad-hoc', 'app-store-connect' => 'app-store' }.freeze
    attr_reader :config, :runner

    def initialize(config, runner)
      @config, @runner = config, runner
    end

    def resolve!
      workspace, project = config.value('workspace').to_s, config.value('project').to_s
      raise Error, 'workspace 和 project 只填写其中一个。' unless workspace.empty? || project.empty?
      choices = {}
      if workspace.empty? && project.empty?
        candidates = Dir.glob(File.join(config.root, '*.xcworkspace')).sort
        candidates = Dir.glob(File.join(config.root, '*.xcodeproj')).sort if candidates.empty?
        path = choose('打包工程', candidates)
        key = path.end_with?('.xcworkspace') ? 'workspace' : 'project'
        choices[key] = Pathname(path).relative_path_from(Pathname(config.root)).to_s
        key == 'workspace' ? workspace = choices[key] : project = choices[key]
      end
      @selection = workspace.empty? ? ['-project', project] : ['-workspace', workspace]
      raise Error, '工程路径已失效，请更新 jfbuild/config.yml。' unless File.directory?(config.absolute(@selection.last))
      raw = runner.run(['xcodebuild', *@selection, '-list', '-json'], label: '读取工程 Scheme', chdir: config.root, capture: true)
      parsed = JSON.parse(raw)
      schemes = (parsed['workspace'] || parsed['project'] || {}).fetch('schemes', [])
      @scheme = config.value('scheme').to_s
      if @scheme.empty?
        @scheme = choose('共享 Scheme', schemes)
        choices['scheme'] = @scheme
      elsif !schemes.include?(@scheme)
        raise Error, '配置中的 Scheme 不存在，请更新 jfbuild/config.yml 的 scheme，并确认它是共享 Scheme。'
      end
      config.save_choices!(choices) unless choices.empty?
    rescue JSON::ParserError
      raise Error, 'Xcode 未返回有效的工程信息，详情见读取日志。'
    end

    def archive(mode, output)
      config.activate_mode(mode)
      resolve! unless @selection && @scheme
      install_signing!
      path = File.join(output, 'App.xcarchive')
      command = ['xcodebuild', *@selection, '-scheme', @scheme, '-configuration', config.mode(mode).fetch('configuration'),
                 '-destination', 'generic/platform=iOS', '-archivePath', path, 'DEBUG_INFORMATION_FORMAT=dwarf-with-dsym']
      team = config.section('signing')['team_id'].to_s
      command << "DEVELOPMENT_TEAM=#{team}" unless team.empty?
      runner.run(command + provisioning_arguments + ['archive'], label: '归档', chdir: config.root)
      app_in_archive(path)
      path
    end

    def export(archive, mode, output, method: nil)
      config.activate_mode(mode)
      info = app_info(app_in_archive(archive))
      directory = File.join(output, 'ipa', "#{Time.now.strftime('%Y%m%d-%H%M%S')}-#{SecureRandom.hex(3)}")
      FileUtils.mkdir_p(directory)
      options = export_options(mode)
      options['method'] = method if method
      options['method'] = compatible_method(options['method'])
      plist = File.join(output, 'ExportOptions.plist')
      Native.write_plist(options, plist)
      runner.run(['xcodebuild', '-exportArchive', '-archivePath', archive, '-exportPath', directory,
                  '-exportOptionsPlist', plist, *provisioning_arguments], label: '导出 IPA', chdir: config.root)
      files = Dir.glob(File.join(directory, '*.ipa'))
      raise Error, '导出结果必须且只能包含一个 IPA。' unless files.length == 1
      exported = BundleGuard.ipa_info(files.first)
      %w[CFBundleIdentifier CFBundleShortVersionString CFBundleVersion].each do |key|
        raise Error, '导出后的包名、版本或构建号与归档不一致，已停止上传。' unless exported[key].to_s == info[key].to_s
      end
      files.first
    end

    def export_options(mode)
      config.activate_mode(mode)
      signing = config.section('signing')
      options = { 'method' => config.mode(mode).fetch('export_method'), 'destination' => 'export', 'manageAppVersionAndBuildNumber' => false }
      style = signing.fetch('style', 'project')
      raise Error, 'signing.style 只能为 project、automatic 或 manual。' unless %w[project automatic manual].include?(style)
      options['signingStyle'] = style unless style == 'project'
      options['teamID'] = signing['team_id'] unless signing['team_id'].to_s.empty?
      options['signingCertificate'] = signing['certificate'] unless signing['certificate'].to_s.empty?
      profile_modes = signing['provisioning_profiles'] || {}
      raise Error, 'signing.provisioning_profiles 必须按包类型填写描述文件映射。' unless profile_modes.is_a?(Hash)
      profiles = profile_modes[mode] || {}
      raise Error, 'provisioning_profiles 必须按 Bundle ID 填写 Profile 名称或 UUID。' unless profiles.is_a?(Hash)
      unless profiles.all? { |bundle_id, profile| bundle_id.is_a?(String) && !bundle_id.strip.empty? && profile.is_a?(String) && !profile.strip.empty? }
        raise Error, '描述文件映射中的 Bundle ID 和 Profile 名称或 UUID 不能为空。'
      end
      if style == 'manual' && profiles.empty?
        raise Error, "手动签名请填写 signing.provisioning_profiles.#{mode}，按 Bundle ID 指定描述文件名称或 UUID。"
      end
      options['provisioningProfiles'] = profiles unless profiles.empty?
      options
    end

    def install_signing!
      signing = config.section('signing')
      certificates = signing['p12']
      certificates = [{ 'path' => certificates, 'password' => signing['p12_password'] }] if certificates.is_a?(String) && !certificates.empty?
      certificates = [] if certificates.nil? || certificates == ''
      raise Error, 'signing.p12 必须是路径或证书配置列表。' unless certificates.is_a?(Array)
      certificates.each do |certificate|
        certificate = { 'path' => certificate, 'password' => signing['p12_password'] } if certificate.is_a?(String)
        raise Error, 'P12 证书条目需要 path 和可选 password。' unless certificate.is_a?(Hash)
        command = ['security', 'import', config.file(certificate['path'], label: 'P12 签名文件'), '-P', certificate['password'].to_s, '-T', '/usr/bin/codesign']
        command += ['-k', config.absolute(signing['keychain'])] unless signing['keychain'].to_s.empty?
        runner.run(command, label: '导入签名证书', acceptable_failure: /SecKeychainItemImport[^\n]*already exists/i)
      end
      profiles = signing['profiles'] || []
      raise Error, 'signing.profiles 必须是文件路径列表。' unless profiles.is_a?(Array)
      profiles.each do |relative|
        path = config.file(relative, label: '描述文件')
        plist = Distribution.decode_profile(File.binread(path))
        uuid = plist['UUID'].to_s
        raise Error, '描述文件缺少有效 UUID。' unless uuid.match?(/\A[0-9a-f-]+\z/i)
        Distribution.check_expiry!(plist)
        ['Library/MobileDevice/Provisioning Profiles', 'Library/Developer/Xcode/UserData/Provisioning Profiles'].each do |directory|
          target = File.join(Dir.home, directory)
          FileUtils.mkdir_p(target)
          FileUtils.cp(path, File.join(target, "#{uuid}.mobileprovision"))
        end
      end
    end

    def validate_signing!
      signing = config.section('signing')
      certificates = signing['p12']
      certificates = [certificates] if certificates.is_a?(String) && !certificates.empty?
      certificates = [] if certificates.nil? || certificates == ''
      raise Error, 'signing.p12 必须是路径或证书配置列表。' unless certificates.is_a?(Array)
      certificates.each { |item| config.file(item.is_a?(Hash) ? item['path'] : item, label: 'P12 签名文件') }
      profiles = signing.fetch('profiles', [])
      raise Error, 'signing.profiles 必须是文件路径列表。' unless profiles.is_a?(Array)
      profiles.each do |path|
        profile = Distribution.decode_profile(File.binread(config.file(path, label: '描述文件')))
        Distribution.check_expiry!(profile)
      end
      provisioning_arguments
    end

    def app_in_archive(archive)
      apps = Dir.glob(File.join(archive, 'Products', 'Applications', '*.app'))
      raise Error, '归档中必须且只能有一个主 App。' unless apps.length == 1
      apps.first
    end

    def app_info(app)
      Native.read_plist(File.join(app, 'Info.plist'))
    end

    private

    def compatible_method(method)
      @help ||= runner.run(['xcodebuild', '-help'], label: '读取导出方法', capture: true)
      available = ->(name) { @help.match?(/(?<![A-Za-z0-9_-])#{Regexp.escape(name)}(?![A-Za-z0-9_-])/) }
      return method if available.call(method)
      alternate = METHOD_ALIASES[method] || METHOD_ALIASES.key(method)
      alternate && available.call(alternate) ? alternate : method
    end

    def choose(label, candidates)
      raise Error, "#{label}：未找到可用选项，请在 jfbuild/config.yml 手动填写。" if candidates.empty?
      return candidates.first if candidates.length == 1
      raise Error, "#{label}存在多个选项，请预先在 jfbuild/config.yml 填写 workspace／project 和 scheme；运行过程不等待选择。"
    end

    def provisioning_arguments
      return [] unless config.boolean(config.section('signing')['allow_provisioning_updates'], 'signing.allow_provisioning_updates')
      result = ['-allowProvisioningUpdates']
      apple = config.section('appstore')
      unless apple['key_id'].to_s.empty? || apple['issuer_id'].to_s.empty?
        result += ['-authenticationKeyPath', config.file(apple['key_file'], label: 'Apple 上传私钥'),
                   '-authenticationKeyID', apple['key_id'], '-authenticationKeyIssuerID', apple['issuer_id']]
      end
      result
    end
  end
end
