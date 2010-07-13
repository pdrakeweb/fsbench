#!/usr/bin/env ruby

###
### Paramters (getopt is overrated)
### ARGV[0] is assumed to be desired result tarball name
###

TMP_FOLDER = "~/fsbench-data"
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
### Test can be repeated several times
###

iterations.times do |i|
  ###
  ### Run tests with various combinations
  ###

  filesizes.each do |fsize|
    record_sizes.each do |rsize|
      result_tag = "Fs#{fsize}_Rs#{rsize}_Np#{np}"
      f = "-F "; np.times { |p| f << "#{tmp_folder}/#{result_tag}_tmp_#{p} " }
      args = "#{processors} -s #{fsize} -r #{rsize} -R -b #{result_tag}.xls -j 1 #{f} "
      args << "| tee -a " + File.join(tmp_folder, "#{result_tag}.out")

      `./iozone #{args}`
      puts "... FAIL!!!!!!" unless $?.success?
    end
  end

  ###
  ### Package and cleanup
  ###

  # Make up a useful tarball name if none provided
  tarball_tag = ARGV[0] ? ARGV[0].dup() : `uname -n` + '-' + `uname -p`
  tarball_tag << "-fsbench"

  # Add suffix if necessary
  j = 0
  tarball = File.join(res_folder, '#{tarball_tag}-#{i.to_s}.0.tbz2')
  while File.exists?(tarball) do
    j = j + 1
    tarball = File.join(res_folder, '#{tarball_tag}-#{i.to_s}.#{j.to_s}.tbz2')
  end

  # Do it
  `tar cjf #{res_folder}/#{tarball} #{tmp_folder}/*.out #{tmp_folder}/*.xls`
  `rm -f #{tmp_folder}/*.out #{tmp_folder}/*.xls`
end
