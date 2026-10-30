module JFBuild
  module Distribution
    def self.decode_profile(bytes)
      profile = Native.call('read-profile', input: bytes)
      raise Error, '描述文件内容不是有效对象。' unless profile.is_a?(Hash)
      profile
    rescue Error
      raise
    rescue StandardError
      raise Error, '无法读取 Apple 描述文件，请检查文件是否完整。'
    end

    def self.check_expiry!(profile)
      raise Error, '描述文件缺少有效期。' if profile['ExpirationDate'].to_s.empty?
      expiry = Time.iso8601(profile['ExpirationDate'])
      raise Error, '描述文件已过期，请更新签名材料。' if expiry <= Time.now
    rescue ArgumentError
      raise Error, '描述文件有效期格式不正确。'
    end

    def self.kind(profile)
      entitlements = profile['Entitlements']
      raise Error, '描述文件缺少签名权限信息。' unless entitlements.is_a?(Hash)
      return 'enterprise' if profile['ProvisionsAllDevices'] == true
      if profile['ProvisionedDevices'].is_a?(Array) && !profile['ProvisionedDevices'].empty?
        return entitlements['get-task-allow'] == true ? 'development' : 'ad-hoc'
      end
      raise Error, '无法确认安装包分发类型。' if entitlements['get-task-allow'] == true
      'app-store'
    end

    def self.validate!(ipa, service)
      profiles = Native.call('ipa-profiles', ipa)
      main_type = kind(profiles.find { |entry| entry['main'] }.fetch('profile'))
      profiles.each do |entry|
        profile = entry.fetch('profile')
        check_expiry!(profile)
        raise Error, '主 App 和扩展的分发类型不一致。' unless kind(profile) == main_type
        info = entry.fetch('info')
        identifier = profile['Entitlements']['application-identifier'].to_s.split('.', 2).last
        unless identifier && File.fnmatch?(identifier, info['CFBundleIdentifier'].to_s)
          raise Error, '描述文件与安装包内的 Bundle ID 不匹配。'
        end
      end
      if service == 'pgyer' && main_type == 'app-store'
        raise Error, '检测到 App Store 安装包，无法通过蒲公英直接安装，请使用测试分发包。'
      end
      if service == 'appstore' && main_type != 'app-store'
        raise Error, '检测到测试或企业分发包，上传 App Store Connect 需要商店分发包。'
      end
      main_type
    end
  end
end
