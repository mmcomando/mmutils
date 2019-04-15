set terminal png size 1024,512
set output 'distribution.png'

#set xdata time
#set timefmt "%S"
set xlabel "XX"

set autoscale

set ylabel "TT"
set format y "%s"

set title "seq number over time"
set key reverse Left outside
set grid

set style data linespoints

set output 'distribution.png'
plot "distribution_this.data" using 1:2 title "Distribution", \
     "distribution_this_fib.data" using 1:2 title "Distribution fib", \
