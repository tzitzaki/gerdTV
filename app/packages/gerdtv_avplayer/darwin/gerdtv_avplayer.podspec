# gerdTV's AVPlayer engine (pubspec.yaml); one source for iOS and macOS.
Pod::Spec.new do |s|
  s.name             = 'gerdtv_avplayer'
  s.version          = '0.0.1'
  s.summary          = 'gerdTV: AVPlayer with a Flutter texture and Picture-in-Picture.'
  s.homepage         = 'https://github.com/tzitzaki/gerdTV'
  s.license          = { :type => 'GPL-3.0' }
  s.author           = 'gerdTV'
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.swift'
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.deployment_target = '26.0'
  s.osx.deployment_target = '26.0'
  s.frameworks       = 'AVFoundation', 'AVKit'
  s.swift_version    = '5.0'
end
