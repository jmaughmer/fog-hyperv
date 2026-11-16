# frozen_string_literal: true

require 'test_helper'

class UnitPSErrorTest < Minitest::Test
  # What WinRM hands run_cmd: the two streams and the exit code, and for most of
  # the cases below the exit code is the only thing that says the call failed
  Response = Struct.new(:stdout, :stderr, :exitcode)

  def perror(stdout: '', stderr: '', exitcode: 1)
    Fog::Hyperv::Errors::PSError.new(Response.new(stdout, stderr, exitcode), 'When executing Get-VM')
  end

  # A cmdlet that finds nothing to act on writes to neither stream and still exits
  # with 1, and run_cmd raises for any non-zero exit code, so this is the common
  # case. A message of nil turns whatever reports it into a NoMethodError.
  def test_message_without_a_word_from_powershell
    assert_includes perror.message, 'PowerShell exited with code 1 without an error message'
  end

  def test_message_when_only_carriage_returns_arrived
    assert_includes perror(stderr: "\r\n").message, 'without an error message'
  end

  # A native command writes its complaint to stdout, which is then the only thing
  # worth quoting
  def test_message_reads_stdout_when_the_error_stream_stayed_empty
    message = perror(stdout: "curl: (22) The requested URL returned error: 404\r\n").message
    assert_includes message, 'writing to stdout instead: curl: (22) The requested URL returned error: 404'
  end

  # The line that ends in the error record id is the one that says what went wrong,
  # and it is what collection.rb matches on to raise NotFound instead
  def test_message_prefers_the_line_carrying_the_error_id
    message = perror(
      stderr: "Get-VM : Hyper-V was unable to find a virtual machine with name \"x\". (0x80070002)\r\n" \
              "+ CategoryInfo : ObjectNotFound: (x:String) [Get-VM], VirtualMachineException\r\n"
    ).message
    assert_equal 'Get-VM : Hyper-V was unable to find a virtual machine with name "x". (0x80070002)', message
  end

  # Without an id the last line before the position, script and stack information
  # is the closest thing to a sentence
  def test_message_without_an_error_id_reads_the_last_line
    message = perror(
      stderr: "Get-VM : Cannot bind argument to parameter 'Name' because it is an empty string.\r\n"
    ).message
    assert_equal "Get-VM : Cannot bind argument to parameter 'Name' because it is an empty string.", message
  end
end
