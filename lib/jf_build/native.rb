require 'open3'

module JFBuild
  module Native
    def self.call(action, *paths, input: '')
      output, status = Open3.capture2('/usr/bin/python3', File.join(__dir__, 'native.py'), action, *paths, stdin_data: input)
      unless status.success?
        message = action == 'project-options' ? '读取工程候选项失败，请手动填写工程和 Scheme。' : '读取安装包或签名材料失败，请检查文件是否完整。'
        raise Error, message
      end
      JSON.parse(output)
    rescue Errno::ENOENT
      raise Error, '未找到 Xcode 命令行工具，请先安装并选择 Xcode。'
    end

    def self.read_plist(path)
      call('read-plist', path)
    end

    def self.write_plist(value, path)
      call('write-plist', path, input: JSON.generate(value))
    end
  end
end
