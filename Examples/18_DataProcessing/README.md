# 18_DataProcessing

Download the CSV dataset from the following URL and process it:
https://ourworldindata.org/grapher/population-growth-rates.csv?v=1&csvType=full&useColumnShortNames=true

For each unique Entity in the dataset:

- Calculate a 5-year sliding window average of the growth rate and store it as `five_y_avg`
- Calculate the percentage deviation of each data point relative to its corresponding `five_y_avg` and store it as `win_loss`
- Export the results as a separate JSON file per Entity
