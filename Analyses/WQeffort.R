# Winter starts in Dec, push to next year
require(discretewq) # water quality data https://github.com/sbashevkin/discretewq
require(deltamapr) # SubRegions dataset https://github.com/InteragencyEcologicalProgram/deltamapr
require(dplyr)
require(sf)
require(lubridate)
require(hms)
require(tidyr)
require(purrr)
require(rlang)
require(readr)
require(dtplyr) # To speed things up
require(ggplot2) # Plotting
require(geofacet) # plotting


# Subregions organized on a geographic grid for geofacetted plots
mygrid <- data.frame(
  name = c("Upper Sacramento River Ship Channel", "Cache Slough and Lindsey Slough", "Lower Sacramento River Ship Channel", "Liberty Island", "Upper Sacramento River", "Suisun Marsh", "Middle Sacramento River", "Lower Cache Slough", "Steamboat and Miner Slough", "Upper Mokelumne River", "Lower Mokelumne River", "Sacramento River near Ryde", "Sacramento River near Rio Vista", "Grizzly Bay", "West Suisun Bay", "Mid Suisun Bay", "Honker Bay", "Confluence", "Lower Sacramento River", "San Joaquin River at Twitchell Island", "San Joaquin River at Prisoners Pt", "Disappointment Slough", "Lower San Joaquin River", "Franks Tract", "Holland Cut", "San Joaquin River near Stockton", "Mildred Island", "Middle River", "Old River", "Rock Slough and Discovery Bay", "Upper San Joaquin River", "Grant Line Canal and Old River", "Victoria Canal"),
  row = c(2, 2, 2, 2, 2, 3, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 5, 5, 5, 5, 6, 6, 6, 6, 6, 7, 7, 7, 8, 8, 8),
  col = c(7, 4, 6, 5, 8, 2, 8, 6, 7, 9, 8, 7, 6, 2, 1, 2, 3, 4, 5, 6, 8, 9, 5, 6, 7, 9, 8, 8, 7, 6, 9, 8, 7),
  code = c(" 1", " 1", " 2", " 3", " 32", " 8", " 4", " 5", " 6", " 7", " 9", "11", "12", "13", "14", "15", "16", "17", "18", "19", "20", "21", "22", "23", "24", "25", "26", "27", "28", "33", "30", "29", "31"),
  stringsAsFactors = FALSE
)

Low_salinity_zone<-read_csv("Outputs/Low_salinity_zone.csv")
Regions<-read_csv("Outputs/Rosies_regions.csv")

## Load Delta Shapefile from Brian
Delta<-deltamapr::R_EDSM_Subregions_Mahardja_FLOAT%>%
  filter(SubRegion%in%unique(Regions$SubRegion))%>%  #Filter to regions of interest
  dplyr::select(SubRegion)

Data<-wq(End_year=2021,
         Sources = c("EMP", "STN", "FMWT", "DJFMP", "SKT", "20mm", "Suisun",
                     "Baystudy", "USGS"))

WQeffort<-function(variable, region="LSZ"){
  
  if(!region%in%c("LSZ", "All")){
    stop("region must be either 'LSZ' or 'All'")
  }
  
  vardata<-Data%>% # Select all long-term surveys (excluding EDSM and the USBR Sacramento ship channel study)
    filter(!is.na(.data[[variable]]) & !is.na(Latitude) & !is.na(Datetime) & !is.na(Longitude) & !is.na(Date))%>% #Remove any rows with NAs in our key variables
    mutate(Datetime = with_tz(Datetime, tz="America/Phoenix"), #Convert to a timezone without daylight savings time
           Date = with_tz(Date, tz="America/Phoenix"), # Calculate difference from noon for each data point for later filtering
           Station=paste(Source, Station),
           Time=as_hms(Datetime), # Create variable for time-of-day, not date. 
           Noon_diff=abs(hms(hours=12)-Time))%>% # Calculate difference from noon for each data point for later filtering
    lazy_dt()%>% # Use dtplyr to speed up operations
    group_by(Station, Source, Date)%>%
    filter(Noon_diff==min(Noon_diff))%>% # Select only 1 data point per station and date, choose data closest to noon
    filter(Time==min(Time))%>% # When points are equidistant from noon, select earlier point
    ungroup()%>%
    as_tibble()%>% # End dtplyr operation
    st_as_sf(coords=c("Longitude", "Latitude"), crs=4326, remove=FALSE)%>% # Convert to sf object
    st_transform(crs=st_crs(Delta))%>% # Change to crs of Delta
    st_join(Delta, join=st_intersects)%>% # Add subregions
    filter(!is.na(SubRegion))%>% # Remove any data outside our subregions of interest
    st_drop_geometry()%>% # Drop sf geometry column since it's no longer needed
    lazy_dt()%>% # Use dtplyr to speed up operations
    group_by(SubRegion)%>%
    mutate(var_sd=sd(.data[[variable]]), var_ext=(.data[[variable]]-mean(.data[[variable]]))/var_sd)%>% # Calculate variable SD for each subregion, then the number of SD's each data point exceeds the mean
    ungroup()%>%
    as_tibble()%>% # End dtplyr operation
    filter(var_ext<10)%>% # Filter out any data points that are more than 10 SDs away from the mean of each subregion
    mutate(Year=if_else(Month==12, Year+1, Year), # Move Decembers to the following year
           Season=case_when(Month%in%3:5 ~ "Spring", # Create seasonal variables
                            Month%in%6:8 ~ "Summer",
                            Month%in%9:11 ~ "Fall",
                            Month%in%c(12, 1, 2) ~ "Winter",
                            TRUE ~ NA_character_))%>%
    lazy_dt()%>% # Use dtplyr to speed up operations
    group_by(Month, Season, SubRegion, Year)%>%
    summarise(var_month_mean=mean(.data[[variable]]), N=n())%>% # Calculate monthly mean, variance, sample size
    ungroup()%>%
    as_tibble()%>% # End dtplyr operation
    complete(nesting(Month, Season), SubRegion, Year, fill=list(N=0))%>% # Fill in NAs for variable (and 0 for N) for any missing month, subregion, year combinations to make sure all months are represented in each season
    lazy_dt()%>% # Use dtplyr to speed up operations
    group_by(Season, SubRegion, Year)%>%
    summarise(N_months=length(unique(Month[which(N>0)])), N=sum(N))%>% # Calculate seasonal mean variable, seasonal sd as the sqrt of the mean monthly variance, total seasonal sample size
    ungroup()%>%
    as_tibble()%>% # End dtplyr operation
    {if(region=="LSZ"){ # For FLOAT analysis
      left_join(., select(Low_salinity_zone, -N), 
                by=c("Season", "SubRegion", "Year"))%>% # Add low salinity zone designations
        filter(Long_term | Short_term) # Remove any data outside the low salinity zone
    }else{ # For Drought analysis
      left_join(., Regions, 
                by=c("Season", "SubRegion"))%>% # Add low salinity zone designations
        filter(Long_term) # Remove any data not chosen for the long-term analysis
    }
    } 
  
  cat(paste("\nFinished", variable, "\n"))
  
  return(vardata)
}

# Run for temp and secchi
vars<-set_names(c("Temperature", "Secchi"))
WQ_list<-map(vars, WQeffort, region="All")


# Plot number of months sampled in each region, season and year for Temp
p_effort_longterm<-ggplot(WQ_list$Temperature)+
  geom_tile(aes(x=Year, y=Season, fill=N_months))+
  scale_fill_viridis_c()+
  scale_x_continuous(breaks=seq(1970, 2020, by=10))+
  scale_y_discrete(limits=rev)+
  facet_geo(~SubRegion, grid=filter(mygrid, name%in%unique(filter(Regions, Long_term)$SubRegion)), labeller=label_wrap_gen(width=18))+
  ylab("Month")+
  theme_bw()+
  theme(axis.text.x=element_text(angle=45, hjust=1), panel.grid=element_blank(), text=element_text(size=16), legend.position=c(0.4, 0.65), 
        legend.background = element_rect(color="black"), panel.background = element_rect(color="black"), legend.margin=margin(10,10,15,10))

ggsave(p_effort_longterm, file="Outputs/Salinity sampling effort_longterm.png",
       device="png", width=15, height=18, units="in")

# Calculate overall min number of month sampled for each year and season for temperature
Data_temp<-WQ_list$Temperature%>%
  group_by(Year, Season)%>%
  summarise(N_Months_min=min(N_months, na.rm=T), .groups="drop")

p_effort_longterm_overall<-ggplot(Data_temp)+
  geom_tile(aes(x=Year, y=Season, fill=N_Months_min))+
  scale_fill_viridis_c()+
  scale_x_continuous(breaks=seq(1970, 2020, by=10))+
  scale_y_discrete(limits=rev)+
  ylab("Month")+
  theme_bw()+
  theme(axis.text.x=element_text(angle=45, hjust=1), panel.grid=element_blank(), text=element_text(size=16), 
        legend.background = element_rect(color="black"), panel.background = element_rect(color="black"), legend.margin=margin(10,10,15,10))
ggsave(p_effort_longterm_overall, file="Outputs/Salinity sampling effort_longterm_overall.png",
       device="png", width=8, height=6, units="in")

# Make sure that this method produces the same NAs we found in the index dataset
Drought_indices<-read_csv("Outputs/Drought_Temp_Secchi.csv")%>%
  filter(!is.na(Temperature))%>%
  mutate(ID=paste(Year, Season))

Data_temp_3<-filter(Data_temp, N_Months_min>=3)%>%
  mutate(ID=paste(Year, Season))

setdiff(Data_temp_3$ID, Drought_indices$ID)
setdiff(Drought_indices$ID, Data_temp_3$ID)
