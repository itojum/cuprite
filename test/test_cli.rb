# frozen_string_literal: true

require "test_helper"
require "stringio"

class TestCLI < Minitest::Test
  def run_cli(*args)
    out = StringIO.new
    err = StringIO.new
    status = Cuprite::CLI.new(out: out, err: err).run(args)
    [status, out.string, err.string]
  end

  def test_build_writes_pack_and_copies_to_world
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "cuprite.yml"), "namespace: demo\nworld: world\n")
      Dir.mkdir(File.join(dir, "src"))
      File.write(File.join(dir, "src/main.rb"), "nil\n")
      status, out, err = Dir.chdir(dir) { run_cli("build") }
      assert_equal 0, status, err
      assert_match "wrote", out
      assert File.file?(File.join(dir, "build/demo/pack.mcmeta"))
      assert File.file?(File.join(dir, "build/demo/data/demo/function/main.mcfunction"))
      assert File.file?(File.join(dir, "world/datapacks/demo/data/demo/function/__init.mcfunction"))
    end
  end

  def test_build_reports_compile_errors_with_location
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "cuprite.yml"), "namespace: demo\n")
      Dir.mkdir(File.join(dir, "src"))
      File.write(File.join(dir, "src/main.rb"), "nil\nx = (\n")
      status, _, err = run_cli("build", "-c", File.join(dir, "cuprite.yml"))
      assert_equal 1, status
      assert_match(%r{src/main\.rb:\d+: syntax error}, err)
    end
  end

  def test_missing_config
    Dir.mktmpdir do |dir|
      status, _, err = Dir.chdir(dir) { run_cli("build") }
      assert_equal 1, status
      assert_match "cuprite.yml not found", err
    end
  end

  def test_usage
    status, _, err = run_cli("frobnicate")
    assert_equal 2, status
    assert_match "usage", err
  end

  def test_build_rejects_blank_entry_without_traceback
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "cuprite.yml"), "namespace: demo\nentry:\n")
      status, _out, err = Dir.chdir(dir) { run_cli("build") }
      assert_equal 1, status
      assert_match "cuprite: cuprite.yml: entry", err
    end
  end

  def test_build_rejects_dot_namespace_and_keeps_siblings
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "cuprite.yml"), "namespace: .\n")
      Dir.mkdir(File.join(dir, "src"))
      File.write(File.join(dir, "src/main.rb"), "nil\n")
      FileUtils.mkdir_p(File.join(dir, "build/other"))
      status, _out, err = Dir.chdir(dir) { run_cli("build") }
      assert_equal 1, status
      assert_match "namespace", err
      assert File.directory?(File.join(dir, "build/other"))
    end
  end
end

