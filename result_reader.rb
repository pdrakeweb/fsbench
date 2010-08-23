#!/usr/bin/env ruby

require 'pp'
require 'fileutils'
require 'optparse'
require 'ostruct'

###
### GETOPT
###
options = OpenStruct.new

optparse = OptionParser.new do |opts|
  opts.on('-m', '--metrics a,b,c', Array, 'list of regex to plot (no flag = all plots)') { |l| options.metrics = l }
  opts.on('-g', '--generation-only', "Stop after generating LaTeX report (no compile or display)") { |b| options.i_maek_lousy_latex = b }
  opts.on('-h', '--help', 'display this screen') do
    puts "Usage: #{$0} [opts] file1 file2 ..."
    o = opts.to_s().split("\n"); o.shift; puts o; exit
  end
end
optparse.parse!

metric_filters = []
options.metrics && options.metrics.each { |m| metric_filters << Regexp.new(m) }

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
### parse-o-matic : parse IOZone output into a hash
###

def parseomatic(file)
  res = {}
  op = :error
  fsize = -1
  rsize = -1

  f = File.open(file, 'r').each_line do |line|
    fsize = ($1.to_i() / 1024) if line =~ /File size set to ([0-9]+) KB/
    rsize = ($1.to_i() / 1024) if line =~ /Record Size ([0-9]+) KB/
    np = $1.to_i() if line =~ /Min process = ([0-9]+)/

    if line =~ /Children see throughput for\s+[0-9]\s+([a-zA-Z\- ]+)\s+=\s+([0-9.]+) KB/
      op = "#{$1.chop}-F#{fsize}-R#{rsize}"
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
### ARGV[0:n] : tarballs to unpack
### _MUST_ be named whatever-NN.tbz2
### whatever is tag, NN is iteration
### whatevers are compared, NN are used to compute deviation
###

results = {}

ARGV.each do |f|
  unless File.exists?(f)
    puts "File not found: #{f}"
    next
  end

  # extract information from tarball name
  unless f =~ /(.*)-([0-9.]*).tbz2/
    puts "File #{f} has improper name"
    next
  end
  batch_tag = $1.split('/').last()
  batch_ver = $2

  # unpacks tarball in temp dir
  FileUtils.mkdir("/tmp/fsbench") unless File.exists?("/tmp/fsbench")
  d = "/tmp/fsbench/" + File.basename(f)
  system("cp #{f} #{d}")
  system("cd /tmp/fsbench; tar xjf #{d}")

  # munch output files
  Dir::glob("/tmp/fsbench/**/*.out").each do |outfile|
#    puts " - #{outfile}"
    results[batch_tag] ||= {}
    results[batch_tag][batch_ver] ||= {}
    new_poney = parseomatic(outfile)
    results[batch_tag][batch_ver].merge!(new_poney)
  end

  # wipe temp dir
  system("rm -rf /tmp/fsbench")
end

###
### deviation, mean, for each operation
### (aggregates same-tag / same-op data of different versions)
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

# Remove stuff if metrics were specified on the CLI
keyset = aggregated_by_op.keys.clone
filtered_keyset = []
metric_filters.each do |re|
  part = keyset.map { |k| k if re.match(k) }
  filtered_keyset = filtered_keyset + part.compact
end
aggregated_by_op.delete_if { |o,v| not filtered_keyset.include? (o) } unless metric_filters.empty?

# Prepare LaTeX source
require 'erb'
tpl = ERB.new(IO.readlines('report/template.tex').join())
stuff = tpl.result(binding)
File.open("report/report.tex", "w") { |io| io.write(stuff) }
exit(0) if options.i_maek_lousy_latex

# Run LaTeX and open up pdf if successful
system('pdflatex -interaction=nonstopmode -halt-on-error -output-directory=report report/report.tex')
system('pdflatex -interaction=nonstopmode -halt-on-error -output-directory=report report/report.tex') # two times, for toc
system('okular --page 2 --unique report/report.pdf') if $?.success?
