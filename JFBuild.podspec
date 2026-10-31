Pod::Spec.new do |s|
  s.name = 'JFBuild'
  s.version = '0.2.1'
  s.summary = 'iOS 打包、导出与上传工具'
  s.homepage = 'https://github.com/jiefun/JFBuild'
  s.source = { :git => "#{s.homepage}.git", :tag => s.version.to_s }
  s.author = 'jfun'
  s.license = { :type => 'MIT', :file => 'LICENSE' }
  s.platform = :ios
  s.preserve_paths = 'jbuild', 'lib/**/*', 'templates/*', 'tools/**/*', 'skills/**/*', 'README.md'
end
