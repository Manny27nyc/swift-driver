//===--------------- DarwinToolchain.swift - Swift Darwin Toolchain -------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
import TSCBasic
import SwiftOptions

/// Toolchain for Darwin-based platforms, such as macOS and iOS.
///
/// FIXME: This class is not thread-safe.
public final class DarwinToolchain: Toolchain {
  public let env: [String: String]

  /// Doubles as path cache and point for overriding normal lookup
  private var toolPaths = [Tool: AbsolutePath]()

  /// The executor used to run processes used to find tools and retrieve target info.
  public let executor: DriverExecutor

  /// The file system to use for any file operations.
  public let fileSystem: FileSystem

  public init(env: [String: String], executor: DriverExecutor, fileSystem: FileSystem = localFileSystem) {
    self.env = env
    self.executor = executor
    self.fileSystem = fileSystem
  }

  /// Retrieve the absolute path for a given tool.
  public func getToolPath(_ tool: Tool) throws -> AbsolutePath {
    // Check the cache
    if let toolPath = toolPaths[tool] {
      return toolPath
    }
    let path = try lookupToolPath(tool)
    // Cache the path
    toolPaths[tool] = path
    return path
  }

  private func lookupToolPath(_ tool: Tool) throws -> AbsolutePath {
    switch tool {
    case .swiftCompiler:
      return try lookup(executable: "swift-frontend")
    case .dynamicLinker:
      return try lookup(executable: "ld")
    case .staticLinker:
      return try lookup(executable: "libtool")
    case .dsymutil:
      return try lookup(executable: "dsymutil")
    case .clang:
      return try lookup(executable: "clang")
    case .swiftAutolinkExtract:
      return try lookup(executable: "swift-autolink-extract")
    case .lldb:
      return try lookup(executable: "lldb")
    case .dwarfdump:
      return try lookup(executable: "dwarfdump")
    case .swiftHelp:
      return try lookup(executable: "swift-help")
    }
  }

  public func overrideToolPath(_ tool: Tool, path: AbsolutePath) {
    toolPaths[tool] = path
  }

  /// Path to the StdLib inside the SDK.
  public func sdkStdlib(sdk: AbsolutePath) -> AbsolutePath {
    sdk.appending(RelativePath("usr/lib/swift"))
  }

  public func makeLinkerOutputFilename(moduleName: String, type: LinkOutputType) -> String {
    switch type {
    case .executable: return moduleName
    case .dynamicLibrary: return "lib\(moduleName).dylib"
    case .staticLibrary: return "lib\(moduleName).a"
    }
  }

  public func defaultSDKPath(_ target: Triple?) throws -> AbsolutePath? {
    let hostIsMacOS: Bool
    #if os(macOS)
    hostIsMacOS = true
    #else
    hostIsMacOS = false
    #endif

    if target?.isMacOSX == true || hostIsMacOS {
      let result = try executor.checkNonZeroExit(
        args: "xcrun", "-sdk", "macosx", "--show-sdk-path",
        environment: env
      ).spm_chomp()
      return AbsolutePath(result)
    }

    return nil
  }

  public var shouldStoreInvocationInDebugInfo: Bool {
    // This matches the behavior in Clang.
    !(env["RC_DEBUG_OPTIONS"]?.isEmpty ?? false)
  }

  public func runtimeLibraryName(
    for sanitizer: Sanitizer,
    targetTriple: Triple,
    isShared: Bool
  ) throws -> String {
    return """
    libclang_rt.\(sanitizer.libraryName)_\
    \(targetTriple.darwinPlatform!.libraryNameSuffix)\
    \(isShared ? "_dynamic.dylib" : ".a")
    """
  }

  enum ToolchainValidationError: Error, DiagnosticData {
    case osVersionBelowMinimumDeploymentTarget(String)
    case iOSVersionAboveMaximumDeploymentTarget(Int)

    var description: String {
      switch self {
      case .osVersionBelowMinimumDeploymentTarget(let target):
        return "Swift requires a minimum deployment target of \(target)"
      case .iOSVersionAboveMaximumDeploymentTarget(let version):
        return "iOS \(version) does not support 32-bit programs"
      }
    }
  }

  public func validateArgs(_ parsedOptions: inout ParsedOptions,
                           targetTriple: Triple) throws {
    // TODO: Validating arclite library path when link-objc-runtime.

    // Validating apple platforms deployment targets.
    try validateDeploymentTarget(&parsedOptions, targetTriple: targetTriple)

    // TODO: Validating darwin unsupported -static-stdlib argument.
    // TODO: If a C++ standard library is specified, it has to be libc++.
  }

  func validateDeploymentTarget(_ parsedOptions: inout ParsedOptions,
                                targetTriple: Triple) throws {
    // Check minimum supported OS versions.
    if targetTriple.isMacOSX,
       targetTriple.version(for: .macOS) < Triple.Version(10, 9, 0) {
      throw ToolchainValidationError.osVersionBelowMinimumDeploymentTarget("OS X 10.9")
    }
    // tvOS triples are also iOS, so check it first.
    else if targetTriple.isTvOS,
            targetTriple.version(for: .tvOS(.device)) < Triple.Version(9, 0, 0) {
      throw ToolchainValidationError.osVersionBelowMinimumDeploymentTarget("tvOS 9.0")
    } else if targetTriple.isiOS {
      if targetTriple.version(for: .iOS(.device)) < Triple.Version(7, 0, 0) {
        throw ToolchainValidationError.osVersionBelowMinimumDeploymentTarget("iOS 7")
      }
      if targetTriple.arch?.is32Bit == true,
         targetTriple.version(for: .iOS(.device)) >= Triple.Version(11, 0, 0) {
        throw ToolchainValidationError.iOSVersionAboveMaximumDeploymentTarget(targetTriple.version(for: .iOS(.device)).major)
      }
    } else if targetTriple.isWatchOS,
              targetTriple.version(for: .watchOS(.device)) < Triple.Version(2, 0, 0) {
      throw ToolchainValidationError.osVersionBelowMinimumDeploymentTarget("watchOS 2.0")
    }
  }
}
