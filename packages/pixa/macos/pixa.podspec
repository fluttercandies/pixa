Pod::Spec.new do |s|
  s.name             = 'pixa'
  s.version          = '1.0.0'
  s.summary          = 'Production-oriented Flutter image loading, caching, and pipeline primitives.'
  s.description      = <<-DESC
Production-oriented Flutter image loading, caching, and pipeline primitives.
                       DESC
  s.homepage         = 'https://github.com/fluttercandies/pixa'
  s.author           = { 'FlutterCandies' => 'https://github.com/fluttercandies' }
  s.source           = { :path => '.' }
  s.source_files     = 'pixa/Sources/pixa/**/*'
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '10.15'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
