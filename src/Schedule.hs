{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

module Schedule
  ( nextEvent
  , eventSummary
  , dayOfWeek
  , Schedule(..)
  ) where

import Control.Monad
import Data.Aeson
import Data.Aeson.Types
import Data.Either.Extra
import Data.Function
import Data.List
import qualified Data.Map as M
import Data.Maybe
import Data.Maybe.Extra
import Data.Monoid
import qualified Data.Text as T
import Data.Time
import Data.Time.Calendar.WeekDate
import Data.Time.Clock.POSIX
import Data.Time.Extra
import Data.Time.LocalTime (TimeZone)
import Safe
import Text.InterpolatedString.QM

data DayOfWeek
  = Monday
  | Tuesday
  | Wednesday
  | Thursday
  | Friday
  | Saturday
  | Sunday
  deriving (Eq, Ord, Enum, Show, Bounded)

dayOfWeek :: Day -> DayOfWeek
dayOfWeek day =
  toEnumNote
    [qms|{s} is not a correct week number according to
         ISO 8601 Week Date format.|]
    (s - 1)
  where
    (_, _, s) = toWeekDate day

newtype ScheduleTimeZone =
  ScheduleTimeZone TimeZone
  deriving (Show)

data Project = Project
  { projectName :: T.Text
  , projectDescription :: T.Text
  , projectUrl :: T.Text
  , projectDays :: [DayOfWeek]
  , projectTime :: TimeOfDay
  , projectChannel :: T.Text
  , projectStarts :: Maybe Day
  , projectEnds :: Maybe Day
  } deriving (Show)

data Event = Event
  { eventDate :: Day
  , eventTime :: TimeOfDay
  , eventTitle :: T.Text
  , eventDescription :: T.Text
  , eventUrl :: T.Text
  , eventChannel :: T.Text
  } deriving (Show)

eventId :: ScheduleTimeZone -> Event -> EventId
eventId timeZone event =
  EventId $ floor $ utcTimeToPOSIXSeconds $ eventUTCTime timeZone event

eventUTCTime :: ScheduleTimeZone -> Event -> UTCTime
eventUTCTime (ScheduleTimeZone timeZone) Event { eventDate = day
                                               , eventTime = timeOfDay
                                               } =
  localTimeToUTC timeZone localTime
  where
    localTime = LocalTime day timeOfDay

eventSummary :: ScheduleTimeZone -> UTCTime -> Event -> T.Text
eventSummary timezone now event = do
  let t = eventUTCTime timezone event
  -- TODO(#755): Diff time for past events in eventSummary should be `finished - (started + DURATION)`
  if t >= now
    then let d = diffUTCTime t now
          in [qms|{eventTitle event}
                  starts in {humanReadableDiffTime d}|]
    else let d = diffUTCTime now t
          in [qms|{eventTitle event}
                  finished {humanReadableDiffTime d} ago|]

newtype EventId =
  EventId Int
  deriving (Eq, Ord, Show)

data EventPatch = EventPatch
  { eventPatchTitle :: Maybe T.Text
  , eventPatchDescription :: Maybe T.Text
  , eventPatchUrl :: Maybe T.Text
  , eventPatchChannel :: Maybe T.Text
  } deriving (Show)

data Schedule = Schedule
  { scheduleProject :: [Project]
  , scheduleExtraEvents :: [Event]
  , scheduleCancelledEvents :: [EventId]
  , scheduleTimezone :: ScheduleTimeZone
  , schedulePatches :: M.Map EventId EventPatch
  } deriving (Show)

instance FromJSON Schedule where
  parseJSON (Object v) =
    Schedule <$> v .: "projects" <*> v .: "extraEvents" <*>
    v .: "cancelledEvents" <*>
    v .: "timezone" <*>
    v .: "eventPatches"
  parseJSON invalid = typeMismatch "Schedule" invalid

instance FromJSON Project where
  parseJSON (Object v) =
    Project <$> v .: "name" <*> v .: "description" <*> v .: "url" <*>
    v .: "days" <*>
    v .: "time" <*>
    v .: "channel" <*>
    v .:? "starts" <*>
    v .:? "ends"
  parseJSON invalid = typeMismatch "Project" invalid

instance FromJSON Event where
  parseJSON (Object v) =
    Event <$> v .: "date" <*> v .: "time" <*> v .: "title" <*>
    v .: "description" <*>
    v .: "url" <*>
    v .: "channel"
  parseJSON invalid = typeMismatch "Event" invalid

instance FromJSON EventId where
  parseJSON = fmap EventId . parseJSON

instance FromJSONKey EventId where
  fromJSONKey = EventId <$> fromJSONKey

parseTimeZone :: T.Text -> Parser TimeZone
parseTimeZone "Asia/Novosibirsk" = return $ minutesToTimeZone 420
parseTimeZone s = fail ("Unknown timezone: " ++ T.unpack s)

instance FromJSON ScheduleTimeZone where
  parseJSON (String s) = ScheduleTimeZone <$> parseTimeZone s
  parseJSON invalid = typeMismatch "ScheduleTimeZone" invalid

instance FromJSON EventPatch where
  parseJSON (Object v) =
    EventPatch <$> v .:? "title" <*> v .:? "description" <*> v .:? "url" <*>
    v .:? "channel"
  parseJSON invalid = typeMismatch "EventPatch" invalid

instance FromJSON DayOfWeek where
  parseJSON =
    maybeFail "Unknown day of week" . toEnumMay . (\x -> x - 1) <=< parseJSON

cancelEvents :: ScheduleTimeZone -> [EventId] -> [Event] -> [Event]
cancelEvents timeZone cancelledIds =
  filter (\e -> eventId timeZone e `notElem` cancelledIds)

makeEvent :: Day -> Project -> Event
makeEvent day project =
  Event
    { eventDate = day
    , eventTime = projectTime project
    , eventTitle = projectName project
    , eventDescription = projectDescription project
    , eventUrl = projectUrl project
    , eventChannel = projectChannel project
    }

between :: Day -> Project -> Bool
between day project =
  getAll $
  fromMaybe (All True) $
  mappend
    (All . (<= day) <$> projectStarts project)
    (All . (day <=) <$> projectEnds project)

projectsOfDay :: Day -> [Project] -> [Event]
projectsOfDay day projects =
  map (makeEvent day) $
  filter (\p -> weekDay `elem` projectDays p && between day p) projects
  where
    weekDay = dayOfWeek day

recurringEventsFrom :: Day -> [Project] -> [Event]
recurringEventsFrom day projects =
  projectsOfDay day projects ++ recurringEventsFrom (succ day) projects

eventsFrom :: Day -> Schedule -> [Event]
eventsFrom day schedule@Schedule { scheduleTimezone = timezone
                                 , scheduleCancelledEvents = cancelledIds
                                 , schedulePatches = patches
                                 } =
  sortBy
    (compare `on` eventDate)
    (map patchEvent (extraEvents <> recurringEvents))
  where
    recurringEvents =
      take 100 $
      cancelEvents timezone cancelledIds $
      recurringEventsFrom day $ scheduleProject schedule
    extraEvents =
      cancelEvents timezone cancelledIds $
      filter ((>= day) . eventDate) $ scheduleExtraEvents schedule
    applyPatch :: Event -> EventPatch -> Event
    applyPatch event patch =
      event
        { eventTitle = fromMaybe (eventTitle event) (eventPatchTitle patch)
        , eventDescription =
            fromMaybe (eventDescription event) (eventPatchDescription patch)
        , eventUrl = fromMaybe (eventUrl event) (eventPatchUrl patch)
        , eventChannel =
            fromMaybe (eventChannel event) (eventPatchChannel patch)
        }
    patchEvent :: Event -> Event
    patchEvent event =
      maybe event (applyPatch event) $ M.lookup (eventId timezone event) patches

nextEvent :: Schedule -> UTCTime -> Either String Event
nextEvent schedule timePoint =
  maybeToEither "No events found" $
  find ((> timePoint) . eventUTCTime (scheduleTimezone schedule)) $
  eventsFrom (utctDay timePoint) schedule
