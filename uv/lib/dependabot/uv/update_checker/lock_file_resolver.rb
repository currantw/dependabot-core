# typed: strong
# frozen_string_literal: true

require "sorbet-runtime"

require "dependabot/errors"
require "dependabot/package/release_cooldown_options"
require "dependabot/uv/version"
require "dependabot/uv/requirement"
require "dependabot/uv/update_checker"
require "dependabot/uv/update_checker/latest_version_finder"
require "dependabot/uv/file_updater/lock_file_updater"

module Dependabot
  module Uv
    class UpdateChecker
      class LockFileResolver
        extend T::Sig

        sig do
          params(
            dependency: Dependabot::Dependency,
            dependency_files: T::Array[Dependabot::DependencyFile],
            credentials: T::Array[Dependabot::Credential],
            repo_contents_path: T.nilable(String),
            security_advisories: T::Array[Dependabot::SecurityAdvisory],
            ignored_versions: T::Array[String],
            update_cooldown: T.nilable(Dependabot::Package::ReleaseCooldownOptions)
          ).void
        end
        def initialize(
          dependency:,
          dependency_files:,
          credentials:,
          repo_contents_path: nil,
          security_advisories: [],
          ignored_versions: [],
          update_cooldown: nil
        )
          @dependency = dependency
          @dependency_files = dependency_files
          @credentials = credentials
          @repo_contents_path = repo_contents_path
          @security_advisories = security_advisories
          @ignored_versions = ignored_versions
          @update_cooldown = update_cooldown
        end

        sig { params(requirement: T.nilable(String)).returns(T.nilable(Dependabot::Uv::Version)) }
        def latest_resolvable_version(requirement:)
          return nil unless requirement

          req = Uv::Requirement.new(requirement)
          current_version = dependency.version && Uv::Version.new(dependency.version)

          # Highest allowed version, honouring ignore conditions and the requirement upper bound.
          target_version = highest_allowed_version(requirement: req)

          # Use it when it's newer than the current version and uv can resolve to it.
          if target_version && (current_version.nil? || target_version > current_version) &&
             resolvable_to?(target_version)
            return target_version
          end

          # Otherwise report the current version when it still satisfies the requirement.
          current_version if current_version && req.satisfied_by?(current_version)
        end

        sig { params(_version: T.anything).returns(T::Boolean) }
        def resolvable?(_version)
          # Always return true since we don't actually attempt resolution
          # This is just a placeholder implementation
          true
        end

        sig { returns(T.nilable(Dependabot::Uv::Version)) }
        def lowest_resolvable_security_fix_version
          # Delegate to LatestVersionFinder which handles security advisory filtering
          fix_version = latest_version_finder.lowest_security_fix_version
          return nil if fix_version.nil?

          # Return the fix version cast to Uv::Version
          Uv::Version.new(fix_version.to_s)
        end

        private

        sig { returns(Dependabot::Dependency) }
        attr_reader :dependency

        sig { returns(T::Array[Dependabot::DependencyFile]) }
        attr_reader :dependency_files

        sig { returns(T::Array[Dependabot::Credential]) }
        attr_reader :credentials

        sig { returns(T.nilable(String)) }
        attr_reader :repo_contents_path

        sig { returns(T::Array[Dependabot::SecurityAdvisory]) }
        attr_reader :security_advisories

        sig { returns(T::Array[String]) }
        attr_reader :ignored_versions

        sig { returns(T.nilable(Dependabot::Package::ReleaseCooldownOptions)) }
        attr_reader :update_cooldown

        # Highest version to resolve to, honouring ignore conditions and requirement upper bound.
        sig { params(requirement: Dependabot::Uv::Requirement).returns(T.nilable(Dependabot::Uv::Version)) }
        def highest_allowed_version(requirement:)
          latest = latest_version_finder.latest_version
          return nil unless latest

          version = Uv::Version.new(latest.to_s)
          return nil unless requirement.satisfied_by?(version)

          version
        end

        # Runs the uv resolver to check whether the sub-dependency can be bumped to target_version.
        sig { params(target_version: Dependabot::Uv::Version).returns(T::Boolean) }
        def resolvable_to?(target_version)
          updated_dependency = Dependabot::Dependency.new(
            name: dependency.name,
            version: target_version.to_s,
            previous_version: dependency.version,
            requirements: [],
            previous_requirements: [],
            package_manager: "uv"
          )

          FileUpdater::LockFileUpdater.new(
            dependencies: [updated_dependency],
            dependency_files: dependency_files,
            credentials: credentials,
            repo_contents_path: repo_contents_path
          ).updated_dependency_files

          true
        rescue Dependabot::DependabotError, SharedHelpers::HelperSubprocessFailed
          false
        end

        sig { returns(LatestVersionFinder) }
        def latest_version_finder
          @latest_version_finder ||= T.let(
            LatestVersionFinder.new(
              dependency: dependency,
              dependency_files: dependency_files,
              credentials: credentials,
              ignored_versions: ignored_versions,
              security_advisories: security_advisories,
              cooldown_options: update_cooldown,
              raise_on_ignored: false
            ),
            T.nilable(LatestVersionFinder)
          )
        end
      end
    end
  end
end
