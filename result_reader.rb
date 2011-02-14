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

require 'pp'
require 'fileutils'
require 'optparse'
require 'ostruct'

TempDir = "/tmp/fsbench-result-reader"

###
### op_map : map operation string used by latency data to strings
###          used by output data ...
###

op_map = {}
op_map["randrol"] = "random readers"
op_map["randwol"] = "random writers"
op_map["revol"] = "reverse readers"
op_map["rol"] = "readers"
op_map["rrol"] = "re readers"
op_map["rwol"] = "rewriters"
op_map["strol"] = "stride readers"
op_map["wol"] = "initial writers"

# this list is only for optionparser documentation
metrics = [ "client", "parent", "min", "max", "avg", "min_xfer",
            "latency_min", "latency_max", "latency_avg", "latency_dev" ]

###
### GETOPT
###
options = OpenStruct.new
options.metrics = "parent", "latency"

optparse = OptionParser.new do |opts|
  odoc = "List of regexps matching operations to plot (no flag = all plots). Available operations are #{op_map.values.join(",")}"
  opts.on('-o', '--operations a,b,c', Array, odoc) { |l| options.operations = l }

  mdoc = "List of regexps matching metrics to plot (default = #{options.metrics.join(",")}). Available metrics are #{metrics.join(",")}"
  opts.on('-m', '--metrics a,b,c', Array, mdoc) { |l| options.metrics = l }

  opts.on('-g', '--generation-only', "Stop after generating LaTeX report (no compile or display)") { |b| options.i_maek_lousy_latex = b }
  opts.on('-v', '--view [VIEWER]', "Launch PDF viewer when done (you can specify your favourite viewer") { |v| options.viewer = v }
  opts.on('-h', '--help', 'display this screen') do
    puts "Usage: #{$0} [opts] file1 file2 ..."
    o = opts.to_s().split("\n"); o.shift; puts o; exit
  end
end
optparse.parse!

abort "You must provide at least one result tarball as argument. \
#{__FILE__} --help for more information." unless ARGV.size > 0

operation_filters = []
options.operations && options.operations.each { |re| operation_filters << Regexp.new(re) }

metric_filters = []
options.metrics && options.metrics.each { |re| metric_filters << Regexp.new(re) }

###
### Statistics utilities
### (extracted from ruby-stats)
###

class Numeric
  def square ; self * self ; end
end

class Array
  def sum ; self.inject(0){|a,x|x+a} ; end
  def mean ; self.sum.to_f/self.size ; end
  def median
    case self.size % 2
      when 0 then self.sort[self.size/2-1,2].mean
      when 1 then self.sort[self.size/2].to_f
    end if self.size > 0
  end
  def histogram ; self.sort.inject({}){|a,x|a[x]=a[x].to_i+1;a} ; end
  def mode
    map = self.histogram
    max = map.values.max
    map.keys.select{|x|map[x]==max}
  end
  def squares ; self.inject(0){|a,x|x.square+a} ; end
  def variance ; self.squares.to_f/self.size - self.mean.square; end
  def deviation ; Math::sqrt( self.variance ) ; end
  def permute ; self.dup.permute! ; end
  def permute!
    (1...self.size).each do |i| ; j=rand(i+1)
      self[i],self[j] = self[j],self[i] if i!=j
    end;self
  end
  def sample n=1 ; (0...n).collect{ self[rand(self.size)] } ; end
end

###
### parse_ioz_output : parse IOZone output into a hash
###

def parse_ioz_output(file)
  res = {}
  op = :error
  fsize = -1
  rsize = -1

  f = File.open(file, 'r').each_line do |line|
    fsize = $1.to_i() if line =~ /File size set to ([0-9]+) KB/
    rsize = $1.to_i() if line =~ /Record Size ([0-9]+) KB/
    np = $1.to_i() if line =~ /Min process = ([0-9]+)/

    if line =~ /Children see throughput for\s+[0-9]\s+([a-zA-Z\- ]+)\s+=\s+([0-9.]+) KB/
      op = "#{$1.chop.gsub("-", " ")}-F#{fsize}-R#{rsize}"
      res[op] ||= {}
      res[op][:client] = $2.to_f()
    end

    res[op][:parent] = $1.to_f() if line =~ /Parent sees[^=]+=\s+([0-9.]+) KB/
    res[op][:min] = $1.to_f() if line =~ /Min throughput[^=]+=\s+([0-9.]+) KB/
    res[op][:max] = $1.to_f() if line =~ /Max throughput[^=]+=\s+([0-9.]+) KB/
    res[op][:avg] = $1.to_f() if line =~ /Avg throughput[^=]+=\s+([0-9.]+) KB/
    res[op][:min_xfer] = $1.to_f() if line =~ /Min xfer[^=]+=\s+([0-9.]+) KB/
  end

  res.each_pair { |op, data| data.each_pair { |k, v| res[op][k] = v / 1024 } }

  return res
end

###
### load_ioz_dat : load/parse IOZone latency datafile info a hash
###                offset data are discarded
###

def load_ioz_dat(file)
  lines = File.readlines(file)
  current = []
  parts = []
  lines.each do |line|
    if line =~ /Offset/
      parts << current
      current = []
    else
      line =~ /(?<off>[0-9]+)[^0-9]+(?<lat>[0-9]+)[^0-9]+(?<chunk>[0-9]+)/
      next unless $~
      current << $~["lat"].to_i
    end
  end
  parts << current
  parts.shift

  # discards other parts in case file was used to
  # record several latency run through.
  return parts[0]
end

###
### sizestr_in_K (str)
###
### 16 => 0.015625
### 16K => 16
### 16M => 16_384
### 16G => 16_777_216
###

def sizestr_in_K (str)
  base = str[0..2].to_i
  return base if str.end_with? "K"
  return base * 1024 if str.end_with? "M"
  return base * 1024 * 1024 if str.end_with? "G"
  return base * 1024 * 1024 * 1024 if str.end_with? "T"
  return base / 1024.0
end

###
### ARGV[0:n] : tarballs to unpack
### _MUST_ be named whatever-NN.tbz2
### whatever is tag, NN is iteration
### whatevers are compared, NN are used to compute deviation
###

results = {}

puts "### Loading files"
ARGV.each do |f|
  unless File.exists?(f)
    puts "File not found: #{f}"
    next
  end

  puts "- #{f}"

  # extract information from tarball name
  unless f =~ /(?<tag>.*)-(?<ver>[0-9.]*).tbz2/
    puts "File #{f} has improper name"
    next
  end
  batch_tag = $~["tag"].split('/').last()
  batch_ver = $~["ver"]
  results[batch_tag] ||= {}
  results[batch_tag][batch_ver] ||= {}

  # unpacks tarball in temp dir
  FileUtils.mkdir(TempDir) unless File.exists?(TempDir)
  d = File.join(TempDir, File.basename(f))
  FileUtils.cp(f, d)
  system("cd #{TempDir}; tar xjf #{d}")

  # process output files
  Dir::glob("#{TempDir}/**/*.out").each do |outfile|
    results[batch_tag][batch_ver].merge!(parse_ioz_output(outfile))
  end

  # process latency files
  latencies = {}
  Dir::glob("#{TempDir}/**/*.dat").each do |datfile|
    bname = File.basename(datfile)
    bname =~ /Fs(?<fs>[^_]+)_Rs(?<rs>[^_]+)_Np[^_]+_Child_(?<c>\d+)_(?<op>[^.]+)\.dat/
    unless $~
      STDERR.puts "Warning: #{bname} has unexpected name"
      next
    end

    fs = sizestr_in_K($~["fs"])
    rs = sizestr_in_K($~["rs"])

    if dat = load_ioz_dat(datfile)
      k = "#{op_map[$~["op"]]}-F#{fs}-R#{rs}"
      latencies[k] ||= []
      latencies[k] << dat
    end
  end

  # aggregate latencies, then merge into results
  latencies.each_pair do |k, data|
    min, max, means, deviations = [], [], [], []
    data.each do |child_data|
      next if child_data.empty?
      min << child_data.min
      max << child_data.max
      means << child_data.mean
      deviations << child_data.deviation
    end

    aggregated_latencies = {}
    aggregated_latencies[:latency_min] = min.min
    aggregated_latencies[:latency_max] = max.max
    aggregated_latencies[:latency_avg] = means.mean
    aggregated_latencies[:latency_dev] = deviations.mean
    results[batch_tag][batch_ver][k].merge!(aggregated_latencies)
  end

  # wipe temp dir
  FileUtils.remove_dir(TempDir, true)
end

puts "### Aggregating all test iterations"

###
### deviation, mean, for each operation
### (aggregates same-tag / same-op data of different iterations)
###

aggregated_by_tag = {}
aggregated_by_op = {}
results.each_pair do |tag, versions|
  puts '- Loaded dataset: ' + tag
  # Reorder data
  reordered = {}
  versions.each_pair do |version, data|
    data.each_pair do |operation, metrics|
      reordered[operation] ||= {}
      metrics.each_pair do |metric, value|
        reordered[operation][metric] ||= []
        reordered[operation][metric] << value
      end
    end
  end

  aggregates = {}
  reordered.each_pair do |operation, data|
    aggregated_by_op[operation] ||= {}

    aggregates[operation] = {}

    metrics = {}
    data.each_pair do |metric, values|
      # remove metrics if specified
      if options.metrics
        pass = false
        metric_filters.each do |re|
          if re.match(metric)
            pass = true
            break
          end
        end
        next unless pass
      end

      # fixme : min max
      metrics[metric] = {}
      metrics[metric][:avg] = values.mean()
      metrics[metric][:dev] = values.deviation()

      aggregated_by_op[operation][metric] ||= {}
      aggregated_by_op[operation][metric][tag] = metrics[metric]
    end
    aggregates[operation] = metrics
  end
  aggregated_by_tag[tag] = aggregates
end

###
### Prepare graphic file (TiKZ/ERB template)
###

puts "### Generating .tex"

# Remove operations if specified
keyset = aggregated_by_op.keys.clone
filtered_keyset = []
operation_filters.each do |re|
  part = keyset.map { |k| k if re.match(k) }
  filtered_keyset = filtered_keyset + part.compact
end
aggregated_by_op.delete_if { |o,v| not filtered_keyset.include? (o) } unless operation_filters.empty?

# Prepare LaTeX source
require 'erb'
tpl = ERB.new(IO.readlines('report/template.tex').join())
stuff = tpl.result(binding)
File.open("report/report.tex", "w") { |io| io.write(stuff) }
exit(0) if options.i_maek_lousy_latex

# Cleanup (LaTeX may not have enough memory to run if this script keeps all of it ...)
puts "### Cleaning up"
aggregated_by_op, aggregated_by_tag, results = nil, nil, nil
GC.start

# Run LaTeX and open up pdf if successful
puts "### Running LaTeX"
system('pdflatex -interaction=nonstopmode -halt-on-error -output-directory=report report/report.tex')
system('pdflatex -interaction=nonstopmode -halt-on-error -output-directory=report report/report.tex') # two times, for toc

if options.viewer
  system('#{options.viewer} --page 2 --unique report/report.pdf') if $?.success?
end
