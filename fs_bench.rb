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

fail "see code or README before running" unless ARGV.size >= 2

###
### Parameters (getopt is overrated)
### ARGV[0] is assumed to be desired result tarball name
###

TMP_FOLDER = ARGV[1]
RES_FOLDER = "~/fsbench-results"
ITERATIONS = 5

###
### Some maintenance around output directories
###

require 'fileutils'
tmp_folder = File.expand_path(TMP_FOLDER)
FileUtils.mkdir(tmp_folder) unless File.exists?(tmp_folder)

res_folder = File.expand_path(RES_FOLDER)
FileUtils.mkdir(res_folder) unless File.exists?(res_folder)

###
### Sets desirable test parameters (other options hardcoded below)
###

filesizes = %w[1G]
record_sizes = %w[16M 64M 128M]

np = `grep -c processor /proc/cpuinfo`.to_i
processors = "-l #{np} -u #{np}"

# tests = "-i 0 -i 1 -i 7 -i 10"

###
### System information collection
###
system_info = {}
system_info["mount"] = `mount`
system_info["cpuinfo"] = `cat /proc/cpuinfo`
system_info["lspci"] = `lspci`
system_info["lsmod"] = `lsmod`
system_info["uname"] = `uname -a`
system_info["sysctl"] = `sysctl -a`
system_info["dmesg-disks"] = `dmesg | grep -P '((s|h)d)|fs'`
system_info["df"] = `df`
system_info["iozone"] = `iozone -version`

# disks = `df | grep ^/dev | sed -r 's#(/dev/[^0-9]+)[0-9]+.*#\1#' | uniq`
# disks.split.each do |drive|
#   system_info["hdparm"] ||= {}
#   system_info["hdparm"][drive] = `hdparm #{drive}`

#   system_info["sdparm"] ||= {}
#   system_info["sdparm"][drive] = `sdparm #{drive}`
# end

system_info_filename = File.join(res_folder, "systeminfo.yml")
File.open(system_info_filename, 'w') { |f| f.write(system_info.to_yaml) }

###
### Test can be repeated several times
### (allowing deviation computation during post processing)
###

ITERATIONS.times do |i|
  puts "#{Time.now} --- Iteration #{i}"

  ###
  ### Run tests with various combinations
  ###

  filesizes.each do |fsize|
    record_sizes.each do |rsize|
      result_tag = "Fs#{fsize}_Rs#{rsize}_Np#{np}"
      f = "-F "; np.times { |p| f << "#{tmp_folder}/#{result_tag}_tmp_#{p} " }
      args = "#{processors} -s #{fsize} -r #{rsize} -R -b #{res_folder}/#{result_tag}.xls -j 1 #{f}"
      args << "| tee -a " + File.join(res_folder, "#{result_tag}.out")

      puts "#{Time.now} - #{fsize} file, #{rsize} record"
      `./iozone #{args}`
      puts "... FAIL!!!!!!" unless $?.success?
    end
  end

  ###
  ### Package and cleanup
  ###

  # Make up a useful tarball name if none provided
  tarball_tag = ARGV[0] ? ARGV[0].dup() : `uname -n`.strip() + '-' + `uname -p`.strip()
  tarball_tag << "-fsbench"

  # Add suffix if necessary
  j = 0
  tarball = File.join(res_folder, "#{tarball_tag}-#{i.to_s}.0.tbz2")
  while File.exists?(tarball) do
    j = j + 1
    tarball = File.join(res_folder, "#{tarball_tag}-#{i.to_s}.#{j.to_s}.tbz2")
  end

  # Do it
  puts "#{Time.now} - Tarballed in #{tarball}"
  `cd #{res_folder}; tar cjf #{tarball} *.out *.xls *.yml`
  `cd #{res_folder}; rm -f *.out *.xls *.yml`
end
