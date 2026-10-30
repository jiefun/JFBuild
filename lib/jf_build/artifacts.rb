module JFBuild
  class Artifacts
    attr_reader :base, :config

    def initialize(config)
      @config = config
      directory = config.section('output').fetch('directory', 'build/jbuild')
      raise Error, '请填写 output.directory。' if directory.to_s.empty?
      @base = config.absolute(directory)
      raise Error, '产物目录不能放在 jfbuild 配置目录内。' if Config.inside?(@base, File.join(config.root, Config::DIRECTORY))
      @base = File.realpath(@base) if File.exist?(@base)
    end

    def with_lock
      FileUtils.mkdir_p(base)
      File.open(File.join(base, '.jbuild.lock'), File::RDWR | File::CREAT, 0o600) do |file|
        raise Error, '本项目已有 jbuild 正在执行，请结束后再运行。' unless file.flock(File::LOCK_EX | File::LOCK_NB)
        yield
      ensure
        file.flock(File::LOCK_UN) if file
      end
    end

    def entries
      return [] unless File.directory?(base)
      Dir.glob(File.join(base, '*', 'record.json')).map do |path|
        directory = File.dirname(path)
        next if File.symlink?(directory) || File.symlink?(path)
        next unless File.basename(directory).match?(/\A\d{8}-\d{6}-[a-f0-9]{6}\z/)
        next unless File.realpath(directory) == directory && File.dirname(directory) == base
        begin
          value = JSON.parse(File.read(path))
          next unless value.is_a?(Hash) && value['jbuild_record'] == 1 && value['project_root'] == config.root
          next unless Plan::MODES.key?(value['mode']) && value['configuration'].is_a?(String) && value['export_method'].is_a?(String)
          value['time'] = Time.iso8601(value.fetch('created_at'))
          value['directory'] = directory
          value['description'] = original_description(directory) unless value.key?('description')
          value
        rescue JSON::ParserError, KeyError, ArgumentError
          nil
        end
      end.compact.sort_by { |record| [record['time'], record['directory']] }.reverse
    end

    def archives
      entries.select do |record|
        app = record['app_directory']
        app.is_a?(String) && File.basename(app) == app && app.end_with?('.app') && record['app'].is_a?(Hash) &&
          valid_path?(record, record['archive']) && File.file?(File.join(record['archive'], 'Products', 'Applications', app, 'Info.plist'))
      end
    end

    def find(archive: nil, ipa: nil)
      archive, ipa = [archive, ipa].map { |path| path && File.expand_path(path) }
      archives.find do |record|
        (archive && record['archive'] == archive) || (ipa && record['ipa'] == ipa && valid_path?(record, ipa))
      end
    end

    def valid_path?(record, path)
      path.is_a?(String) && File.exist?(path) && !File.symlink?(path) &&
        Config.inside?(File.realpath(path), record.fetch('directory')) && path != record.fetch('directory')
    end

    def prune_before_new!
      limit = config.archive_limit
      records = archives.reverse
      removed = []
      while records.length >= limit
        record = records.shift
        FileUtils.remove_entry_secure(record.fetch('directory'))
        removed << record.fetch('directory')
      end
      removed
    end

    def new_directory
      FileUtils.mkdir_p(base)
      path = File.join(base, "#{Time.now.strftime('%Y%m%d-%H%M%S')}-#{SecureRandom.hex(3)}")
      Dir.mkdir(path, 0o700)
      path
    end

    def create(mode, settings, directory: nil, description: '', builder: nil)
      directory ||= new_directory
      record = { 'jbuild_record' => 1, 'project_root' => config.root, 'created_at' => Time.now.iso8601(6),
                 'mode' => mode, 'configuration' => settings.fetch('configuration'), 'export_method' => settings.fetch('export_method'),
                 'directory' => directory, 'description' => description.to_s, 'builder' => builder }
      save(record)
      record
    end

    def save(record)
      data = record.reject { |key, _value| %w[directory time].include?(key) }
      directory = record.fetch('directory')
      Tempfile.create(['record', '.json'], directory) do |file|
        file.chmod(0o600)
        file.write(JSON.pretty_generate(data) + "\n")
        file.close
        File.rename(file.path, File.join(directory, 'record.json'))
      end
    end

    private

    def original_description(directory)
      paths = Dir.glob(File.join(directory, 'results', '*.json')).sort + [File.join(directory, 'result.json')]
      legacy = nil
      paths.each do |path|
        begin
          next unless File.file?(path) && valid_path?({ 'directory' => directory }, path)
          result = JSON.parse(File.read(path))
          next unless result.is_a?(Hash) && result['description'].is_a?(String)
          return result['description'] if result['source'] == 'new'
          legacy ||= result['description'] if result['source'].to_s.empty?
        rescue JSON::ParserError, SystemCallError
          next
        end
      end
      legacy.to_s
    end
  end
end
