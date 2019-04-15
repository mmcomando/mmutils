set terminal png size 1024,512
set output 'compare.png'

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

plot "time_d_std.data" using 1:2 title "D std", \
     "time_this_fib.data" using 1:2 title "My fib", \
     "time_this.data" using 1:2 title "My", \
     "time_cpp_unordered_map.data" using 1:2 title "C++ unordered map", \
#     "time_cpp_map.data" using 1:2 title "C++ map", \
     

