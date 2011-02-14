#!/usr/bin/env ruby

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

# This file is part of FSBench (https://github.com/heliostech/FSBench)
# Elie Bleton <ebleton@heliostech.fr>

require 'optparse'
require 'fileutils'
require 'ostruct'
require 'yaml'

# Options defaults
opts = OpenStruct.new
opts.result_folder = "~/fsbench-results"
opts.test_folder = nil
opts.read_existing_file = nil
opts.tarball_prefix = nil
opts.iterations = 5
opts.measure_latency = true
opts.file_sizes = %w[1M 32M]
opts.block_sizes = %w[4K 512K]
opts.thread_count = `grep -c processor /proc/cpuinfo`.to_i

###
### Option parser configuration
###

$op = OptionParser.new do |o|
  o.banner = "Usage: #{__FILE__} [options]"

  t_doc = "(MANDATORY) Folder where test files will be written/read for testing"
  o.on("-t", "--test-folder DIR", t_doc) { |v| opts.test_folder = v }

  r_doc = "Folder where result tarballs will be stored (default: #{opts.result_folder})"
  o.on("-r", "--result-folder FOLDER", r_doc) { |v| opts.result_folder = v }

  i_doc = "How many times each test will be run (default: #{opts.iterations})"
  o.on("-i", "--iterations COUNT", i_doc) { |v| opts.iterations = v.to_i }

  l_doc = "Do latency measurements (default: #{opts.measure_latency})"
  o.on("-l", "--latency YES|NO", l_doc) do |v|
    x = v == "YES" ? true : (v == "NO" ? false : abort("bad value for --latency"))
    opts.measure_latency = x
  end

  p_doc = "Prefix of the result tarball (default: hostname-mountpoint-mount_type)"
  o.on("-p", "--tarball-prefix PREFIX", p_doc) { |v| opts.tarball_prefix = v }

  p_doc = "Thread count (default: #{opts.thread_count})"
  o.on("-n", "--thread-count COUNT", p_doc) { |v| opts.tarball_prefix = v }

  f_doc = "File sizes to test, comma separated (default: #{opts.file_sizes.join(",")})"
  o.on("-s", "--file-sizes SIZE_LIST", f_doc) { |v| opts.file_sizes = v.split(",") }

  f_doc = "Block sizes to test, comma separated (default: #{opts.block_sizes.join(",")})"
  o.on("-b", "--block-sizes SIZE_LIST", f_doc) { |v| opts.block_sizes = v.split(",") }

  o.on("-h", "--help", "You're reading it") { abort o.to_s }
end.parse!

abort "Test folder is mandatory. #{__FILE__} --help for more information." unless opts.test_folder

abort "You need the iozone binary in your current working directory." unless File.exists?(File.expand_path("./iozone"))

###
### Some maintenance around output directories
###

require 'fileutils'
test_folder = File.expand_path(opts.test_folder)
FileUtils.mkdir(test_folder) unless File.exists?(test_folder)

result_folder = File.expand_path(opts.result_folder)
FileUtils.mkdir(result_folder) unless File.exists?(result_folder)

# Preliminary Cleanup
`rm *.dat; cd #{result_folder}; rm -f *.out *.xls *.yml *.dat`

###
### System information collection
###
system_info = {};
system_info["mount"] = `mount`
system_info["cpuinfo"] = `cat /proc/cpuinfo`
system_info["lspci"] = `lspci 2>/dev/null`
system_info["lsmod"] = `lsmod 2>/dev/null`
system_info["uname"] = `uname -a`
system_info["sysctl"] = `sysctl -a 2>/dev/null`
system_info["dmesg-disks"] = `dmesg | pgrep '((s|h)d)|fs'`
system_info["df"] = `df`
system_info["iozone"] = `./iozone -version`

# disks = `df | grep ^/dev | sed -r 's#(/dev/[^0-9]+)[0-9]+.*#\1#' | uniq`
# disks.split.each do |drive|
#   system_info["hdparm"] ||= {}
#   system_info["hdparm"][drive] = `hdparm #{drive}`

#   system_info["sdparm"] ||= {}
#   system_info["sdparm"][drive] = `sdparm #{drive}`
# end

system_info_filename = File.join(result_folder, "system_info.yml")
File.open(system_info_filename, 'w') { |f| f.write(system_info.to_yaml) }

###
### Sets desirable test parameters (other options hardcoded below)
###

processors = "-l #{opts.thread_count} -u #{opts.thread_count}"
extra = "-j 1 " # stride = 1 means 1 record read at a time
extra << "-p " # purge processor cache
extra << "-Q " if opts.measure_latency

###
### Test can be repeated several times
### (allowing deviation computation during post processing)
###

opts.iterations.times do |i|
  puts "#{Time.now} --- Iteration #{i}"

  ###
  ### Run tests with various combinations
  ###

  opts.file_sizes.each do |fsize|
    opts.block_sizes.each do |rsize|
      result_tag = "Fs#{fsize}_Rs#{rsize}_Np#{opts.thread_count}"

      files = "-F "
      opts.thread_count.times { |p| files << "#{test_folder}/#{result_tag}_tmp_#{p} " }

      args = "#{processors} #{files} #{extra} -s #{fsize} -r #{rsize} "
      args << "-R -b #{result_folder}/#{result_tag}.xls " # Excel output conf
      args << "| tee -a " + File.join(result_folder, "#{result_tag}.out")

      puts "#{Time.now} - #{fsize} file, #{rsize} record"
      `./iozone #{args}`
      puts "iozone failure. Args:\n#{args}" unless $?.success?

      Dir["*dat"].each do |dat|
        File.rename(dat, "#{result_tag}_#{dat}") if dat =~ /^Child/
      end if opts.measure_latency
    end
  end

  ###
  ### Package and cleanup
  ###

  # Make up a useful tarball name if none provided
  unless  opts.tarball_prefix
    opts.tarball_prefix = `uname -n`.strip() + '-' + `uname -m`.strip()
    opts.tarball_prefix << "-fsbench"
  end

  # Add suffix (.0, .1, .2, ..) if necessary
  j = 0
  tarball = File.join(result_folder, "#{opts.tarball_prefix}-#{i.to_s}.0.tbz2")
  while File.exists?(tarball) do
    j = j + 1
    tarball = File.join(result_folder, "#{opts.tarball_prefix}-#{i.to_s}.#{j.to_s}.tbz2")
  end

  # Do it
  puts "#{Time.now} - Tarballed in #{tarball}"
  `mv *.dat #{result_folder}/` if opts.measure_latency
  `cd #{result_folder}; tar cjf #{tarball} *.out *.xls *.yml #{"*.dat" if opts.measure_latency }`

  # Partial cleanup
  `cd #{result_folder}; rm -f *.out *.xls *.dat`
end

# Final cleanup
`rm -f #{result_folder}/*.yml`
